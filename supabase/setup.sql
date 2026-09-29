-- fomo intern desk: database setup for Supabase
-- Paste this whole file into Supabase → SQL Editor → New query, then click Run.
--
-- BEFORE RUNNING: change the manager code on the line marked  <-- CHANGE THIS
-- Anyone can view the desk and add shifts or requests. Only someone with the
-- manager code can approve/reject reimbursements or post the pinned note.

create extension if not exists pgcrypto;

-- ---------- tables ----------
create table if not exists public.shifts (
  id          uuid primary key default gen_random_uuid(),
  name        text not null check (char_length(trim(name)) between 1 and 40),
  date        date not null,
  start_time  time not null,
  end_time    time not null check (end_time > start_time),
  mode        text not null default 'office' check (mode in ('office', 'remote')),
  note        text not null default '' check (char_length(note) <= 120),
  created_at  timestamptz not null default now()
);

create table if not exists public.expenses (
  id           uuid primary key default gen_random_uuid(),
  name         text not null check (char_length(trim(name)) between 1 and 40),
  date         date not null,
  amount_cents integer not null check (amount_cents > 0 and amount_cents <= 1000000),
  category     text not null check (char_length(category) <= 30),
  description  text not null check (char_length(description) between 1 and 160),
  receipt      text not null default '' check (receipt = '' or receipt ~* '^https?://'),
  status       text not null default 'pending' check (status in ('pending', 'approved', 'rejected')),
  created_at   timestamptz not null default now(),
  decided_at   timestamptz
);

create table if not exists public.board (
  id          integer primary key default 1 check (id = 1),
  text        text not null default '' check (char_length(text) <= 600),
  updated_at  timestamptz not null default now()
);
insert into public.board (id, text) values (1, '') on conflict (id) do nothing;

-- The manager code lives in a schema the website cannot read.
create schema if not exists private;
create table if not exists private.settings (
  id        integer primary key default 1 check (id = 1),
  code_hash text not null
);
do $$
declare
  manager_code text := 'PUT-YOUR-CODE-HERE';   -- <-- CHANGE THIS to your own manager code (keep the quotes)
begin
  if manager_code = 'PUT-YOUR-CODE-HERE' or char_length(manager_code) < 6 then
    raise exception 'Pick your own manager code (6+ characters) on the line marked CHANGE THIS, then run again.';
  end if;
  insert into private.settings (id, code_hash) values (1, crypt(manager_code, gen_salt('bf')))
  on conflict (id) do update set code_hash = excluded.code_hash;
end $$;
revoke all on schema private from anon, authenticated;

-- ---------- who can do what (row level security) ----------
grant usage on schema public to anon;
grant select, insert, delete on public.shifts   to anon;
grant select, insert, delete on public.expenses to anon;
grant select                 on public.board    to anon;

alter table public.shifts   enable row level security;
alter table public.expenses enable row level security;
alter table public.board    enable row level security;

drop policy if exists "anyone reads shifts"    on public.shifts;
drop policy if exists "anyone adds shifts"     on public.shifts;
drop policy if exists "anyone removes shifts"  on public.shifts;
create policy "anyone reads shifts"   on public.shifts for select to anon using (true);
create policy "anyone adds shifts"    on public.shifts for insert to anon with check (true);
create policy "anyone removes shifts" on public.shifts for delete to anon using (true);

drop policy if exists "anyone reads expenses"            on public.expenses;
drop policy if exists "anyone submits expenses"          on public.expenses;
drop policy if exists "anyone withdraws pending expenses" on public.expenses;
create policy "anyone reads expenses"   on public.expenses for select to anon using (true);
create policy "anyone submits expenses" on public.expenses for insert to anon
  with check (status = 'pending' and decided_at is null);
create policy "anyone withdraws pending expenses" on public.expenses for delete to anon
  using (status = 'pending');
-- No update policy: statuses can only change through decide_expense() below.

drop policy if exists "anyone reads the board" on public.board;
create policy "anyone reads the board" on public.board for select to anon using (true);

-- ---------- manager-only actions (need the manager code) ----------
create or replace function public.check_manager_code(p_code text)
returns boolean language sql security definer set search_path = public, private, extensions as $$
  select exists (select 1 from private.settings where code_hash = crypt(p_code, code_hash));
$$;

create or replace function public.decide_expense(p_code text, p_id uuid, p_status text)
returns void language plpgsql security definer set search_path = public, private, extensions as $$
begin
  if not public.check_manager_code(p_code) then raise exception 'Wrong manager code'; end if;
  if p_status not in ('pending', 'approved', 'rejected') then raise exception 'Bad status'; end if;
  update public.expenses
     set status = p_status,
         decided_at = case when p_status = 'pending' then null else now() end
   where id = p_id;
end $$;

create or replace function public.post_note(p_code text, p_text text)
returns void language plpgsql security definer set search_path = public, private, extensions as $$
begin
  if not public.check_manager_code(p_code) then raise exception 'Wrong manager code'; end if;
  update public.board set text = left(coalesce(p_text, ''), 600), updated_at = now() where id = 1;
end $$;

revoke all on function public.check_manager_code(text) from public;
revoke all on function public.decide_expense(text, uuid, text) from public;
revoke all on function public.post_note(text, text) from public;
grant execute on function public.check_manager_code(text) to anon;
grant execute on function public.decide_expense(text, uuid, text) to anon;
grant execute on function public.post_note(text, text) to anon;

-- ---------- live updates ----------
do $$ begin
  begin alter publication supabase_realtime add table public.shifts;   exception when duplicate_object then null; end;
  begin alter publication supabase_realtime add table public.expenses; exception when duplicate_object then null; end;
  begin alter publication supabase_realtime add table public.board;    exception when duplicate_object then null; end;
end $$;
