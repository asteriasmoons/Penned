begin;
alter table public.penned_publications add column source_fingerprint text;
alter table public.penned_publications add column published_at timestamptz;
alter table public.penned_publications add column custom_path text unique;
alter table public.penned_publications add column access jsonb not null default '{}';
alter table public.penned_publications add column access_epoch bigint not null default 0;
alter table public.penned_publications add constraint publication_path check(custom_path is null or (custom_path ~ '^[a-z0-9][a-z0-9-]{1,78}[a-z0-9]$' and custom_path !~ '^[a-f0-9]{64}$'));
alter table public.penned_publications add constraint publication_fingerprint check(source_fingerprint is null or source_fingerprint ~ '^[a-f0-9]{64}$');
create table penned_private.reader_grants (
  hash text primary key, publication_id uuid not null references public.penned_publications on delete cascade,
  epoch bigint not null, expires_at timestamptz not null default now()+interval '7 days'
);
create table penned_private.reader_attempts (key text primary key, window_at timestamptz not null default now(), count integer not null default 1);
alter table penned_private.reader_grants enable row level security;
alter table penned_private.reader_attempts enable row level security;
revoke all on penned_private.reader_grants,penned_private.reader_attempts from public,anon,authenticated;
grant all on penned_private.reader_grants,penned_private.reader_attempts to service_role;

create function public.penned_reader_session(p_action text,p_publication uuid default null,p_hash text default null,p_epoch bigint default null)
returns jsonb language plpgsql set search_path='' as $$
declare attempts integer;
begin
  if p_action='limit' then
    delete from penned_private.reader_attempts where window_at<now()-interval '1 day';
    insert into penned_private.reader_attempts(key) values(p_hash)
    on conflict(key) do update set count=case when reader_attempts.window_at<now()-interval '10 minutes' then 1 else reader_attempts.count+1 end,
      window_at=case when reader_attempts.window_at<now()-interval '10 minutes' then now() else reader_attempts.window_at end returning count into attempts;
    return jsonb_build_object('allowed',attempts<=least(500,coalesce(p_epoch,20)));
  elsif p_action='grant' then
    delete from penned_private.reader_grants where expires_at<now();
    insert into penned_private.reader_grants(hash,publication_id,epoch) values(p_hash,p_publication,p_epoch);
    return jsonb_build_object('allowed',true);
  elsif p_action='verify' then
    return jsonb_build_object('allowed',exists(select 1 from penned_private.reader_grants where hash=p_hash and publication_id=p_publication and epoch=p_epoch and expires_at>now()));
  end if;
  raise exception 'publishing_invalid_action';
end $$;
revoke all on function public.penned_reader_session(text,uuid,text,bigint) from public,anon,authenticated;
grant execute on function public.penned_reader_session(text,uuid,text,bigint) to service_role;

drop function public.penned_publication_write(text,uuid,uuid,bigint,text,text,text,jsonb,jsonb);
create function public.penned_publication_write(p_action text,p_owner uuid,p_id uuid default null,p_expected bigint default null,p_library text default null,p_document_id text default null,p_token text default null,p_document jsonb default null,p_settings jsonb default null,p_source text default null,p_access jsonb default null,p_path text default null)
returns jsonb language plpgsql set search_path='' as $$
declare publication public.penned_publications; asset jsonb;
begin
  perform 1 from penned_private.publishing_owners where id=p_owner for update;
  if not found then raise exception 'publishing_unauthorized'; end if;
  if p_action='create' then
    insert into public.penned_publications(owner_id,source_library_id,source_document_id,token)
    values(p_owner,p_library,p_document_id,p_token) on conflict(owner_id,source_library_id,source_document_id) do nothing;
    select * into strict publication from public.penned_publications where owner_id=p_owner and source_library_id=p_library and source_document_id=p_document_id;
    return to_jsonb(publication);
  end if;
  select * into publication from public.penned_publications where id=p_id and owner_id=p_owner for update;
  if not found then raise exception 'publishing_not_found'; end if;
  if publication.version is distinct from p_expected then raise exception 'publishing_conflict'; end if;
  if p_action in ('publish','update') then
    if p_action='update' and not publication.active then raise exception 'publishing_inactive'; end if;
    if p_document is null or p_document->>'schemaVersion'<>'1' or jsonb_typeof(p_document->'media')<>'array' then raise exception 'publishing_invalid_document'; end if;
    for asset in select value from jsonb_array_elements(p_document->'media') loop
      perform 1 from public.penned_publication_media where id=(asset->>'id')::uuid and publication_id=p_id and not retired
        and size=(asset->>'size')::bigint and sha256=asset->>'sha256' and mime_type=asset->>'mimeType' and name=asset->>'name';
      if not found then raise exception 'publishing_missing_media'; end if;
    end loop;
    publication.document:=p_document; publication.active:=true;
    publication.source_fingerprint:=p_source; publication.published_at:=now();
  elsif p_action='unpublish' then publication.active:=false; publication.access_epoch:=publication.access_epoch+1;
  elsif p_action='regenerate' then publication.token:=p_token; publication.custom_path:=null; publication.access_epoch:=publication.access_epoch+1;
  elsif p_action='access' then
    publication.access:=publication.access||coalesce(p_access,'{}');
    publication.access_epoch:=publication.access_epoch+1;
    if p_path is not null then publication.custom_path:=nullif(p_path,''); end if;
  elsif p_action<>'settings' then raise exception 'publishing_invalid_action'; end if;
  publication.settings:=publication.settings||coalesce(p_settings,'{}');
  update public.penned_publications set active=publication.active,token=publication.token,document=publication.document,
    settings=publication.settings,version=version+1,updated_at=now(),source_fingerprint=publication.source_fingerprint,
    published_at=publication.published_at,custom_path=publication.custom_path,access=publication.access,access_epoch=publication.access_epoch
    where id=p_id returning * into publication;
  return to_jsonb(publication);
end $$;
revoke all on function public.penned_publication_write(text,uuid,uuid,bigint,text,text,text,jsonb,jsonb,text,jsonb,text) from public,anon,authenticated;
grant execute on function public.penned_publication_write(text,uuid,uuid,bigint,text,text,text,jsonb,jsonb,text,jsonb,text) to service_role;
commit;
