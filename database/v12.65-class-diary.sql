-- ============================================================================
-- School Connect V12.65 — CLASS DIARY (homework / classwork journal)
-- ----------------------------------------------------------------------------
-- Issue:
--   diary.html has shipped since V5 but nothing ever created the table it
--   reads. DRY.loadEntries() does `sb.from('diary').select('*')`, DRY.post()
--   inserts into it and DRY.ack() updates it — every one of those calls
--   returns 42P01 "relation public.diary does not exist". The page renders an
--   empty list forever, and a teacher who posts an entry is told it failed.
--
--   The complete schema therefore did NOT contain every process on the
--   platform: one whole module was dead on arrival, silently.
--
-- Fix:
--   * public.diary — the journal itself: one row per class/period entry, with
--     classwork, homework, behaviour and a free note, authored by a teacher.
--   * public.diary_ack — one row per parent/student acknowledgement. The
--     frontend also writes an `acks` jsonb array on the diary row, so both
--     shapes are kept and the RPC keeps them in step.
--   * RPCs: sc_diary_ack (acknowledge, idempotent), sc_diary_acks (read back),
--     sc_diary_feed (class-scoped, role-safe feed used by the page).
--   * RLS that matches the rest of the platform: staff read/write their own
--     classes, families read entries for their children's class(es), admins
--     see everything, nobody else sees anything.
--   * Indexes for the three access paths the page actually uses.
--
-- Idempotent — safe to re-run. Folded into complete-schema.sql by
-- tools/build-complete-schema.py, and shipped to every mirrored repo.
-- ============================================================================

-- ---------------------------------------------------------------- 1. the table
create table if not exists public.diary (
  id            uuid primary key default gen_random_uuid(),
  date          date not null default current_date,
  class         text not null default '',
  subject       text,
  period        text,
  classwork     text not null default '',
  homework      text,
  behaviour     text,
  note          text,
  teacher_id    uuid references public.profiles(id) on delete set null,
  teacher_name  text,
  acks          jsonb not null default '[]'::jsonb,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

-- Upgrade safety for anyone who hand-made a partial diary table.
alter table public.diary add column if not exists date date default current_date;
alter table public.diary add column if not exists class text default '';
alter table public.diary add column if not exists subject text;
alter table public.diary add column if not exists period text;
alter table public.diary add column if not exists classwork text default '';
alter table public.diary add column if not exists homework text;
alter table public.diary add column if not exists behaviour text;
alter table public.diary add column if not exists note text;
alter table public.diary add column if not exists teacher_id uuid references public.profiles(id) on delete set null;
alter table public.diary add column if not exists teacher_name text;
alter table public.diary add column if not exists acks jsonb default '[]'::jsonb;
alter table public.diary add column if not exists created_at timestamptz default now();
alter table public.diary add column if not exists updated_at timestamptz default now();

-- ------------------------------------------------- 2. acknowledgements (rows)
create table if not exists public.diary_ack (
  id           uuid primary key default gen_random_uuid(),
  diary_id     uuid not null references public.diary(id) on delete cascade,
  user_id      uuid references public.profiles(id) on delete cascade,
  acks_name    text not null default '',
  role         text not null default '',
  note         text default 'seen',
  created_at   timestamptz not null default now(),
  unique (diary_id, user_id)
);
alter table public.diary_ack add column if not exists acks_name text default '';
alter table public.diary_ack add column if not exists role text default '';
alter table public.diary_ack add column if not exists note text default 'seen';
alter table public.diary_ack add column if not exists created_at timestamptz default now();

-- ------------------------------------------------------------------ 3. indexes
create index if not exists diary_date_idx        on public.diary (date desc);
create index if not exists diary_class_date_idx  on public.diary (class, date desc);
create index if not exists diary_teacher_idx     on public.diary (teacher_id, date desc);
create index if not exists diary_ack_diary_idx   on public.diary_ack (diary_id);

-- ------------------------------------------------------------------ 4. triggers
drop trigger if exists trg_diary_updated_at on public.diary;
create trigger trg_diary_updated_at before update on public.diary
for each row execute function public.sc_set_updated_at();

-- --------------------------------------------------------------------- 5. RLS
alter table public.diary      enable row level security;
alter table public.diary_ack  enable row level security;

-- ---- diary: read
drop policy if exists diary_read_admin on public.diary;
create policy diary_read_admin on public.diary for select
using (public.is_admin(auth.uid()));

drop policy if exists diary_read_staff on public.diary;
create policy diary_read_staff on public.diary for select
using (public.is_staff(auth.uid()));

-- a family reads the entries posted for its own children's class
drop policy if exists diary_read_family on public.diary;
create policy diary_read_family on public.diary for select
using (
  exists (
    select 1 from public.students s
    where s.class = diary.class
      and (s.user_id = auth.uid() or public.is_parent_of(auth.uid(), s.id))
  )
);

-- ---- diary: write (staff own their entries; admins own everything)
drop policy if exists diary_write_staff on public.diary;
create policy diary_write_staff on public.diary for insert to authenticated
with check (
  public.is_staff(auth.uid())
  and (teacher_id is null or teacher_id = auth.uid())
);

drop policy if exists diary_update_staff on public.diary;
create policy diary_update_staff on public.diary for update to authenticated
using (public.is_admin(auth.uid()) or teacher_id = auth.uid())
with check (public.is_admin(auth.uid()) or teacher_id = auth.uid());

drop policy if exists diary_delete_staff on public.diary;
create policy diary_delete_staff on public.diary for delete to authenticated
using (public.is_admin(auth.uid()) or teacher_id = auth.uid());

-- ---- diary_ack: a family or student may acknowledge what it can read
drop policy if exists diary_ack_read on public.diary_ack;
create policy diary_ack_read on public.diary_ack for select
using (
  user_id = auth.uid()
  or public.is_staff(auth.uid())
  or exists (select 1 from public.diary d where d.id = diary_ack.diary_id
             and (public.is_admin(auth.uid()) or public.is_staff(auth.uid())
                  or exists (select 1 from public.students s
                             where s.class = d.class
                               and (s.user_id = auth.uid() or public.is_parent_of(auth.uid(), s.id)))))
);

drop policy if exists diary_ack_insert on public.diary_ack;
create policy diary_ack_insert on public.diary_ack for insert to authenticated
with check (user_id = auth.uid());

-- ------------------------------------------------------------------ 6. RPCs
-- sc_diary_ack: acknowledge in one call, keeping diary.acks and diary_ack in step.
create or replace function public.sc_diary_ack(p_diary_id uuid, p_note text default 'seen')
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_uid uuid := auth.uid(); v_name text := ''; v_role text := '';
        v_row public.diary; v_entry jsonb;
begin
  if v_uid is null then
    return jsonb_build_object('ok', false, 'error', 'not authenticated');
  end if;
  select coalesce(full_name,''), coalesce(role,'') into v_name, v_role
    from public.profiles where id = v_uid;
  select * into v_row from public.diary where id = p_diary_id;
  if v_row.id is null then
    return jsonb_build_object('ok', false, 'error', 'diary entry not found');
  end if;

  insert into public.diary_ack(diary_id, user_id, acks_name, role, note)
  values (p_diary_id, v_uid, v_name, v_role, coalesce(p_note,'seen'))
  on conflict (diary_id, user_id) do update
    set note = excluded.note, acks_name = excluded.acks_name, role = excluded.role;

  v_entry := jsonb_build_object('parent', v_name, 'role', v_role,
                                'note', coalesce(p_note,'seen'), 'at', now());

  -- keep the legacy jsonb array in step with the rows: drop any earlier entry
  -- by this user, then append the current one.
  update public.diary d
     set acks = (
       select coalesce(jsonb_agg(e order by e->>'at'), '[]'::jsonb)
       from jsonb_array_elements(coalesce(d.acks,'[]'::jsonb)) e
       where coalesce(e->>'parent','') <> v_name
          or coalesce(e->>'role','')   <> v_role
     ) || jsonb_build_array(v_entry)
   where d.id = p_diary_id;

  return jsonb_build_object('ok', true, 'diary_id', p_diary_id, 'acks', v_entry);
end $$;
revoke execute on function public.sc_diary_ack(uuid,text) from public, anon;
grant  execute on function public.sc_diary_ack(uuid,text) to authenticated;

-- sc_diary_acks: read the acknowledgements back for one entry.
create or replace function public.sc_diary_acks(p_diary_id uuid)
returns table(acks_name text, role text, note text, created_at timestamptz)
language sql stable security definer set search_path=public as $$
  select a.acks_name, a.role, a.note, a.created_at
  from public.diary_ack a
  where a.diary_id = p_diary_id
  order by a.created_at;
$$;
revoke execute on function public.sc_diary_acks(uuid) from public, anon;
grant  execute on function public.sc_diary_acks(uuid) to authenticated;

-- sc_diary_feed: the page's read. Returns what this caller is allowed to see.
create or replace function public.sc_diary_feed(p_class text default null, p_limit int default 200)
returns jsonb language sql stable security definer set search_path=public as $$
  with visible as (
    select d.*
    from public.diary d
    where (p_class is null or p_class = '' or d.class = p_class)
      and (
        public.is_admin(auth.uid())
        or public.is_staff(auth.uid())
        or exists (select 1 from public.students s
                   where s.class = d.class
                     and (s.user_id = auth.uid() or public.is_parent_of(auth.uid(), s.id)))
      )
    order by d.date desc, d.created_at desc
    limit greatest(1, least(coalesce(p_limit,200), 500))
  )
  select coalesce(jsonb_agg(to_jsonb(v) order by v.date desc, v.created_at desc), '[]'::jsonb)
  from visible v;
$$;
revoke execute on function public.sc_diary_feed(text,integer) from public, anon;
grant  execute on function public.sc_diary_feed(text,integer) to authenticated;

-- ------------------------------------------------------------------ 7. grants
grant select, insert, update, delete on public.diary     to authenticated;
grant select, insert, update, delete on public.diary_ack to authenticated;

-- ------------------------------------------------------------------ 8. marker
do $$ begin
  insert into public.sc_install_state(key, details)
  values ('diary_v1', jsonb_build_object('applied_at', now(), 'version', 'V12.65'))
  on conflict (key) do update set details = excluded.details;
end $$;

select 'V12.65 applied: public.diary + diary_ack, sc_diary_ack, sc_diary_acks, sc_diary_feed' as applied;
