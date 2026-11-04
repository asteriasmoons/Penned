-- Public gallery catalog; only the Edge Function service role may mutate it.
create table if not exists public.penned_gallery_categories (
  id uuid primary key default gen_random_uuid(),
  title text not null check (length(trim(title)) between 1 and 100),
  sort_order double precision not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create table if not exists public.penned_gallery_templates (
  id uuid primary key default gen_random_uuid(),
  category_id uuid not null references public.penned_gallery_categories(id) on delete restrict,
  title text not null check (length(trim(title)) between 1 and 160),
  description text not null default '',
  revision integer not null default 1 check (revision > 0),
  sort_order double precision not null default 0,
  package jsonb not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table public.penned_gallery_categories enable row level security;
alter table public.penned_gallery_templates enable row level security;
revoke all on public.penned_gallery_categories, public.penned_gallery_templates from anon, authenticated;
grant all on public.penned_gallery_categories, public.penned_gallery_templates to service_role;
create index if not exists penned_gallery_templates_category on public.penned_gallery_templates(category_id, sort_order);

create or replace function public.penned_gallery_admin_owner(p_owner uuid, p_subject text)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from penned_private.publishing_owners
    where id = p_owner and provider = 'apple' and subject = p_subject);
$$;
revoke all on function public.penned_gallery_admin_owner(uuid,text) from public, anon, authenticated;
grant execute on function public.penned_gallery_admin_owner(uuid,text) to service_role;
