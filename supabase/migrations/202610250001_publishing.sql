create schema if not exists penned_private;
revoke all on schema penned_private from public, anon, authenticated;
grant usage on schema penned_private to service_role;

create table penned_private.publishing_owners (
  id uuid primary key default gen_random_uuid(),
  provider text not null check (provider in ('apple','email')),
  subject text not null,
  auth_user_id uuid references auth.users(id) on delete cascade,
  revoked_before timestamptz,
  unique(provider, subject),
  check ((provider = 'email') = (auth_user_id is not null))
);
create table penned_private.publishing_sessions (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references penned_private.publishing_owners on delete cascade,
  access_hash text not null unique,
  refresh_hash text not null unique,
  access_expires_at timestamptz not null default now() + interval '15 minutes',
  expires_at timestamptz not null default now() + interval '30 days'
);
create index publishing_sessions_owner on penned_private.publishing_sessions(owner_id);
create table penned_private.publishing_apple_exchanges (
  token_hash text primary key,
  expires_at timestamptz not null
);

create table public.penned_publications (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references penned_private.publishing_owners on delete cascade,
  source_library_id text not null check (length(source_library_id) between 1 and 200),
  source_document_id text not null check (length(source_document_id) between 1 and 200),
  token text not null unique check (token ~ '^[a-f0-9]{64}$'),
  version bigint not null default 0 check(version >= 0),
  active boolean not null default false,
  document jsonb,
  settings jsonb not null default '{"showTitle":true,"showAuthor":false,"showTableOfContents":true,"allowIndexing":false,"authorName":""}',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(owner_id, source_library_id, source_document_id),
  check (not active or document is not null)
);
create table public.penned_publication_media (
  id uuid primary key,
  publication_id uuid not null references public.penned_publications on delete cascade,
  object_path text not null unique,
  name text not null,
  mime_type text not null,
  size bigint not null check(size between 1 and 16777216),
  sha256 text not null check(sha256 ~ '^[a-f0-9]{64}$'),
  retired boolean not null default false,
  created_at timestamptz not null default now()
);
create index penned_publication_media_publication on public.penned_publication_media(publication_id);

alter table public.penned_publications enable row level security;
alter table public.penned_publication_media enable row level security;
alter table penned_private.publishing_owners enable row level security;
alter table penned_private.publishing_sessions enable row level security;
alter table penned_private.publishing_apple_exchanges enable row level security;
revoke all on public.penned_publications, public.penned_publication_media from public, anon, authenticated;
revoke all on penned_private.publishing_owners, penned_private.publishing_sessions, penned_private.publishing_apple_exchanges from public, anon, authenticated;
grant all on public.penned_publications, public.penned_publication_media to service_role;
grant all on penned_private.publishing_owners, penned_private.publishing_sessions, penned_private.publishing_apple_exchanges to service_role;

insert into storage.buckets(id,name,public,file_size_limit)
values ('penned-publications','penned-publications',false,16777216);

create policy penned_publications_private on storage.objects as restrictive for all to anon,authenticated
using (bucket_id <> 'penned-publications') with check (bucket_id <> 'penned-publications');

create function public.penned_publishing_identity(p_provider text, p_subject text, p_auth_user uuid default null)
returns uuid language plpgsql set search_path = '' as $$
declare result uuid;
begin
  insert into penned_private.publishing_owners(provider,subject,auth_user_id)
    values(p_provider,p_subject,p_auth_user) on conflict(provider,subject) do nothing;
  select id into strict result from penned_private.publishing_owners
    where provider=p_provider and subject=p_subject and auth_user_id is not distinct from p_auth_user;
  return result;
end $$;

create function public.penned_publishing_session(p_action text, p_hash text, p_access text default null, p_refresh text default null, p_subject text default null, p_expiry timestamptz default null, p_issued_at timestamptz default null)
returns jsonb language plpgsql set search_path = '' as $$
declare session_row penned_private.publishing_sessions; owner_uuid uuid; cutoff timestamptz;
begin
  if p_action='exchange' then
    delete from penned_private.publishing_apple_exchanges where expires_at < now();
    insert into penned_private.publishing_apple_exchanges values(p_hash,p_expiry);
    owner_uuid := public.penned_publishing_identity('apple',p_subject);
    select revoked_before into cutoff from penned_private.publishing_owners where id=owner_uuid for update;
    if cutoff is not null and (p_issued_at is null or p_issued_at<=cutoff) then raise exception 'publishing_unauthorized'; end if;
    insert into penned_private.publishing_sessions(owner_id,access_hash,refresh_hash)
      values(owner_uuid,p_access,p_refresh) returning * into session_row;
  elsif p_action='refresh' then
    select * into session_row from penned_private.publishing_sessions where refresh_hash=p_hash and expires_at>now() for update;
    if not found then raise exception 'publishing_unauthorized'; end if;
    update penned_private.publishing_sessions set access_hash=p_access,refresh_hash=p_refresh,access_expires_at=least(now()+interval '15 minutes',expires_at)
      where id=session_row.id returning * into session_row;
  elsif p_action='verify' then
    select * into session_row from penned_private.publishing_sessions where access_hash=p_hash and access_expires_at>now() and expires_at>now();
    if not found then raise exception 'publishing_unauthorized'; end if;
  elsif p_action='revoke' then
    delete from penned_private.publishing_sessions where access_hash=p_hash;
    return '{}'::jsonb;
  else raise exception 'publishing_invalid_action'; end if;
  return jsonb_build_object('ownerID',session_row.owner_id,'expiresAt',session_row.access_expires_at,
    'subject',(select subject from penned_private.publishing_owners where id=session_row.owner_id));
end $$;

create function public.penned_publication_write(p_action text,p_owner uuid,p_id uuid default null,p_expected bigint default null,p_library text default null,p_document_id text default null,p_token text default null,p_document jsonb default null,p_settings jsonb default null)
returns jsonb language plpgsql set search_path = '' as $$
declare publication public.penned_publications; asset jsonb;
begin
  perform 1 from penned_private.publishing_owners where id=p_owner for update;
  if not found then raise exception 'publishing_unauthorized'; end if;
  if p_action='create' then
    insert into public.penned_publications(owner_id,source_library_id,source_document_id,token)
      values(p_owner,p_library,p_document_id,p_token)
      on conflict(owner_id,source_library_id,source_document_id) do nothing;
    select * into strict publication from public.penned_publications where owner_id=p_owner and source_library_id=p_library and source_document_id=p_document_id;
    return to_jsonb(publication);
  end if;
  select * into publication from public.penned_publications where id=p_id and owner_id=p_owner for update;
  if not found then raise exception 'publishing_not_found'; end if;
  if publication.version is distinct from p_expected then raise exception 'publishing_conflict'; end if;
  if p_action in ('publish','update') then
    if p_action='update' and not publication.active then raise exception 'publishing_inactive'; end if;
    if p_document is null or p_document->>'schemaVersion' <> '1' or jsonb_typeof(p_document->'media') <> 'array' then raise exception 'publishing_invalid_document'; end if;
    for asset in select value from jsonb_array_elements(p_document->'media') loop
      perform 1 from public.penned_publication_media where id=(asset->>'id')::uuid and publication_id=p_id and not retired
        and size=(asset->>'size')::bigint and sha256=asset->>'sha256' and mime_type=asset->>'mimeType' and name=asset->>'name';
      if not found then raise exception 'publishing_missing_media'; end if;
    end loop;
    publication.document := p_document;
    publication.active := true;
  elsif p_action='unpublish' then publication.active := false;
  elsif p_action='regenerate' then publication.token := p_token;
  elsif p_action<>'settings' then raise exception 'publishing_invalid_action'; end if;
  publication.settings := publication.settings || coalesce(p_settings,'{}'::jsonb);
  update public.penned_publications set active=publication.active,token=publication.token,document=publication.document,
    settings=publication.settings,version=version+1,updated_at=now() where id=p_id returning * into publication;
  return to_jsonb(publication);
end $$;

create function public.penned_publication_media_delete(p_owner uuid,p_id uuid,p_media uuid,p_expected bigint,p_finish boolean default false)
returns jsonb language plpgsql set search_path = '' as $$
declare publication public.penned_publications; asset public.penned_publication_media;
begin
  perform 1 from penned_private.publishing_owners where id=p_owner for update;
  select * into publication from public.penned_publications where id=p_id and owner_id=p_owner for update;
  if not found then raise exception 'publishing_not_found'; end if;
  if publication.version is distinct from p_expected then raise exception 'publishing_conflict'; end if;
  select * into asset from public.penned_publication_media where id=p_media and publication_id=p_id for update;
  if not found then return '{}'::jsonb; end if;
  if exists(select 1 from jsonb_array_elements(publication.document->'media') item where item->>'id'=p_media::text) then raise exception 'publishing_media_in_use'; end if;
  if p_finish then
    delete from public.penned_publication_media where id=p_media and retired;
  else update public.penned_publication_media set retired=true where id=p_media; end if;
  return to_jsonb(asset);
end $$;

create function public.penned_publishing_delete_owner(p_owner uuid)
returns void language plpgsql set search_path = '' as $$
declare provider_name text;
begin
  select provider into provider_name from penned_private.publishing_owners where id=p_owner for update;
  delete from public.penned_publications where owner_id=p_owner;
  delete from penned_private.publishing_sessions where owner_id=p_owner;
  if provider_name='apple' then
    update penned_private.publishing_owners set revoked_before=now() where id=p_owner;
  else delete from penned_private.publishing_owners where id=p_owner; end if;
end
$$;

revoke all on function public.penned_publishing_identity(text,text,uuid), public.penned_publishing_session(text,text,text,text,text,timestamptz,timestamptz), public.penned_publication_write(text,uuid,uuid,bigint,text,text,text,jsonb,jsonb), public.penned_publishing_delete_owner(uuid) from public,anon,authenticated;
grant execute on function public.penned_publishing_identity(text,text,uuid), public.penned_publishing_session(text,text,text,text,text,timestamptz,timestamptz), public.penned_publication_write(text,uuid,uuid,bigint,text,text,text,jsonb,jsonb), public.penned_publishing_delete_owner(uuid) to service_role;
revoke all on function public.penned_publication_media_delete(uuid,uuid,uuid,bigint,boolean) from public,anon,authenticated;
grant execute on function public.penned_publication_media_delete(uuid,uuid,uuid,bigint,boolean) to service_role;
