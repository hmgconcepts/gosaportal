-- =====================================================================
-- School Connect — UPDATE V11 SCHEMA (Enterprise v11)
-- Run AFTER schema.sql (+ v6, v8, v9 updates). Idempotent.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. FEES: remaining balance shown on e-receipts (issue 13)
-- ---------------------------------------------------------------------
alter table public.fee_payments add column if not exists fee_total numeric;
alter table public.fee_payments add column if not exists balance   numeric;
alter table public.fee_payments add column if not exists student_name text;

-- ---------------------------------------------------------------------
-- 2. ADMISSION PREFIX (issue 8 — ROOT CAUSE):
--    The generator rewrites the TABLE DEFAULT to the school acronym, but the
--    settings ROW (id=1) may have been created BEFORE that default applied,
--    or by an older schema — so gen_admission_no() kept using 'SCH'.
--    This backfills the row itself from the default, and lets you set it
--    explicitly below.
-- ---------------------------------------------------------------------
do $$
declare v_default text;
begin
  select column_default into v_default
    from information_schema.columns
   where table_schema='public' and table_name='school_settings' and column_name='admission_prefix';
  -- column_default looks like  'GOSA'::text  — strip the quotes/cast
  v_default := regexp_replace(coalesce(v_default,''), '''([^'']*)''.*', '\1');
  if v_default is not null and v_default <> '' then
    update public.school_settings
       set admission_prefix = 'GOSA'
     where id = 1
       and (admission_prefix is null or admission_prefix in ('', 'SCH', 'STD'));
  end if;
end $$;

-- To change the acronym manually at any time, run:
--   update public.school_settings set admission_prefix = 'YOURACRONYM' where id = 1;
-- (Existing students keep their old numbers; new students use the new prefix.)

-- ---------------------------------------------------------------------
-- 3. NOTIFICATIONS: parents/students/staff must RECEIVE in-app messages.
--    notif_write was staff-only for ALL commands (fine), but read_by
--    updates (mark-as-read) by non-staff were blocked → unread badge
--    never cleared for families. Allow authenticated users to update
--    ONLY the read_by column via a safe RPC.
-- ---------------------------------------------------------------------
create or replace function public.notif_mark_read(p_id uuid)
returns void language plpgsql security definer as $$
begin
  update public.notifications
     set read_by = (
       select coalesce(jsonb_agg(distinct x), '[]'::jsonb)
         from jsonb_array_elements_text(coalesce(read_by,'[]'::jsonb) || to_jsonb(array[auth.uid()::text])) as t(x)
     )
   where id = p_id;
end $$;
grant execute on function public.notif_mark_read(uuid) to authenticated;

alter table public.notifications add column if not exists recipient_id uuid references public.profiles(id) on delete set null;
alter table public.notifications add column if not exists created_by  uuid references public.profiles(id) on delete set null;

-- Families may create PRIVATE notifications (delivery events for their own
-- in-app messages) but nothing school-wide:
drop policy if exists "notif_insert_family" on public.notifications;
create policy "notif_insert_family" on public.notifications for insert
  with check (auth.role() = 'authenticated' and (public.is_staff(auth.uid()) or coalesce(audience,'') in ('private')));

select 'update-v11-schema applied ✔' as status;
