-- School Connect V5.4 focused upgrade: student term metrics.
-- Portability and CBT organization are browser features; this SQL adds report metrics.
create table if not exists public.student_term_metrics(
 id uuid primary key default gen_random_uuid(),student_id uuid references public.students(id)on delete cascade,
 student_id_ref text not null default '',student_name text not null default '',class text not null default '',
 term text not null default '',session text not null default '',height_cm numeric(6,2),weight_kg numeric(6,2),
 blood_pressure text default '',vision text default '',genotype text default '',blood_group text default '',medical_note text default '',
 recorded_by uuid references public.profiles(id)on delete set null,measured_on date default current_date,
 created_at timestamptz default now(),updated_at timestamptz default now(),unique(student_id_ref,student_name,class,term,session)
);
alter table public.student_term_metrics enable row level security;
drop policy if exists metrics_staff_all on public.student_term_metrics;
create policy metrics_staff_all on public.student_term_metrics for all using(public.is_staff(auth.uid()))with check(public.is_staff(auth.uid()));
drop policy if exists metrics_family_read on public.student_term_metrics;
create policy metrics_family_read on public.student_term_metrics for select using(exists(select 1 from public.students s where s.id=student_term_metrics.student_id and(s.user_id=auth.uid()or public.is_parent_of(auth.uid(),s.id))));
create index if not exists student_term_metrics_lookup_idx on public.student_term_metrics(student_id,class,term,session);
notify pgrst,'reload schema';select pg_notify('pgrst','reload schema');
select 'School Connect V5.4 student metrics installed ✅'as status;
