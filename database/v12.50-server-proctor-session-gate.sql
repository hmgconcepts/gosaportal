-- ============================================================================
-- School Connect V12.50 — Server-side proctor session gate (camera-required exams)
-- ----------------------------------------------------------------------------
-- Browser-only permission gate can be bypassed by directly calling submit RPC.
-- For exams whose anti_cheat_config.camera=true, this adds a server-side gate:
-- getUserMedia succeeds -> client registers a short-lived proctor session tied to
-- exam_id + client_ref -> BEFORE INSERT on cbt_results verifies session active,
-- then consumes it. Direct cbt_submit_v5/cbt_submit_v6 calls without a registered
-- proctor session cannot create a result. Normal non-camera exams remain unchanged.
-- Limitation stated honestly: a modified client can call the registration RPC
-- directly; web browsers cannot provide hardware attestation. This blocks UI
-- permission denial and casual API bypass; high-stakes exams still require
-- supervised devices/kiosk or in-person invigilation.
-- ============================================================================
select 'RUNNING: School Connect server proctor session gate V12.50' as running_version;

create table if not exists public.cbt_proctor_sessions(
 id uuid primary key default gen_random_uuid(),
 exam_id uuid not null references public.cbt_exams(id) on delete cascade,
 client_ref text not null,
 student_id_ref text not null default '',
 status text not null default 'active' check(status in ('active','consumed','revoked')),
 started_at timestamptz not null default now(),
 expires_at timestamptz not null default (now()+interval '3 hours'),
 consumed_at timestamptz,
 unique(exam_id,client_ref)
);
alter table public.cbt_proctor_sessions enable row level security;
drop policy if exists cbt_proctor_staff_read on public.cbt_proctor_sessions;
create policy cbt_proctor_staff_read on public.cbt_proctor_sessions for select using(public.is_admin(auth.uid()) or public.is_staff(auth.uid()));
grant select on public.cbt_proctor_sessions to authenticated;

create or replace function public.cbt_proctor_register(p_exam_id uuid,p_client_ref text,p_student_id_ref text default '')
returns jsonb language plpgsql security definer set search_path=public as $$
declare e record; ref text:=trim(coalesce(p_client_ref,'')); sid text:=trim(coalesce(p_student_id_ref,'')); s public.cbt_proctor_sessions%rowtype;
begin
 if ref='' or length(ref)>120 then return jsonb_build_object('ok',false,'error','client_ref_required'); end if;
 select * into e from public.cbt_exams where id=p_exam_id;
 if not found then return jsonb_build_object('ok',false,'error','exam_not_found'); end if;
 if coalesce((e.anti_cheat_config->>'camera')::boolean,false) is not true then return jsonb_build_object('ok',false,'error','camera_not_required'); end if;
 insert into public.cbt_proctor_sessions(exam_id,client_ref,student_id_ref,status,started_at,expires_at)
 values(p_exam_id,ref,sid,'active',now(),now()+interval '3 hours')
 on conflict(exam_id,client_ref) do update set student_id_ref=excluded.student_id_ref,status='active',started_at=now(),expires_at=now()+interval '3 hours',consumed_at=null
 returning * into s;
 return jsonb_build_object('ok',true,'session_id',s.id,'expires_at',s.expires_at,'exam_id',p_exam_id,'client_ref',ref);
end$$;
revoke execute on function public.cbt_proctor_register(uuid,text,text) from public;
grant execute on function public.cbt_proctor_register(uuid,text,text) to anon,authenticated;

create or replace function public.sc_cbt_require_proctor_before_result()
returns trigger language plpgsql security definer set search_path=public as $$
declare required boolean; s public.cbt_proctor_sessions%rowtype;
begin
 select coalesce((anti_cheat_config->>'camera')::boolean,false) into required from public.cbt_exams where id=new.exam_id;
 if required then
   select * into s from public.cbt_proctor_sessions where exam_id=new.exam_id and client_ref=new.client_ref and status='active' and expires_at>now() for update;
   if not found then raise exception using errcode='23514',message='proctor_session_required: camera-required exam has no active server proctor session'; end if;
   update public.cbt_proctor_sessions set status='consumed',consumed_at=now() where id=s.id;
 end if;
 return new;
end$$;
drop trigger if exists trg_cbt_proctor_required_before_result on public.cbt_results;
create trigger trg_cbt_proctor_required_before_result before insert on public.cbt_results for each row execute function public.sc_cbt_require_proctor_before_result();

insert into public.sc_install_state(key,details) values ('v12.50-server-proctor-session-gate.sql','{"self":true}') on conflict (key) do nothing;
notify pgrst,'reload schema';select pg_notify('pgrst','reload schema');
select 'V12.50 server proctor session gate installed — camera-required CBT submissions need a one-use active server session' as status;
