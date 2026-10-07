-- Maths to Failure: schema. Every table is owned by a user and protected by Row Level Security.

create table public.papers (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  name text not null,
  paper_path text,
  memo_path text,
  style_notes text not null default '',
  status text not null default 'uploaded' check (status in ('uploaded', 'extracting', 'done', 'failed')),
  error text,
  question_count int not null default 0,
  created_at timestamptz not null default now(),
  unique (user_id, name)
);

create table public.questions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  paper_id uuid references public.papers(id) on delete cascade,
  qnum text,
  source text not null default 'paper' check (source in ('paper', 'generated')),
  topic text not null,
  skill text not null,
  level smallint not null check (level between 1 and 5),
  marks int not null check (marks > 0),
  question text not null,
  has_diagram boolean not null default false,
  memo jsonb not null,
  final_answer text not null default '',
  verified boolean not null default false,
  created_at timestamptz not null default now(),
  unique (paper_id, qnum)
);

create table public.skills (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  topic text not null,
  skill text not null,
  level smallint not null default 1 check (level between 1 and 5),
  mastery real not null default 0.5 check (mastery between 0 and 1),
  attempts int not null default 0,
  streak int not null default 0,
  fail_streak int not null default 0,
  failed_at smallint check (failed_at between 1 and 5),
  errors jsonb not null default '{}'::jsonb,
  last_attempt_at timestamptz,
  unique (user_id, topic, skill)
);

create table public.attempts (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  skill_id uuid not null references public.skills(id) on delete cascade,
  question_id uuid references public.questions(id) on delete set null,
  question_text text not null,
  generated boolean not null default false,
  level smallint not null,
  marks int not null,
  out_of int not null,
  tags text[] not null default '{}',
  first_error text,
  transcription jsonb,
  disputed boolean not null default false,
  overridden boolean not null default false,
  created_at timestamptz not null default now()
);

create index questions_user_skill_idx on public.questions (user_id, topic, skill);
create index questions_paper_idx on public.questions (paper_id);
create index attempts_user_created_idx on public.attempts (user_id, created_at desc);
create index attempts_skill_idx on public.attempts (skill_id);
create index attempts_question_idx on public.attempts (question_id);

alter table public.papers enable row level security;
alter table public.questions enable row level security;
alter table public.skills enable row level security;
alter table public.attempts enable row level security;

create policy "own rows" on public.papers for all to authenticated
  using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);
create policy "own rows" on public.questions for all to authenticated
  using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);
create policy "own rows" on public.skills for all to authenticated
  using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);
create policy "own rows" on public.attempts for all to authenticated
  using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);

-- Private bucket for the original PDFs. Files live under "<user id>/...".
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('papers', 'papers', false, 26214400, array['application/pdf']);

create policy "own pdf files" on storage.objects for all to authenticated
  using (bucket_id = 'papers' and (storage.foldername(name))[1] = (select auth.uid())::text)
  with check (bucket_id = 'papers' and (storage.foldername(name))[1] = (select auth.uid())::text);
