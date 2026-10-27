begin;
create function public.penned_source_baseline(p_owner uuid,p_id uuid,p_expected bigint,p_source text)
returns jsonb language plpgsql set search_path='' as $$
declare publication public.penned_publications;
begin
  select * into publication from public.penned_publications where id=p_id and owner_id=p_owner for update;
  if not found then raise exception 'publishing_not_found'; end if;
  if not publication.active or publication.version<>p_expected then raise exception 'publishing_conflict'; end if;
  if p_source !~ '^[a-f0-9]{64}$' then raise exception 'publishing_invalid_document'; end if;
  update public.penned_publications set source_fingerprint=p_source,version=version+1 where id=p_id returning * into publication;
  return to_jsonb(publication);
end $$;
revoke all on function public.penned_source_baseline(uuid,uuid,bigint,text) from public,anon,authenticated;
grant execute on function public.penned_source_baseline(uuid,uuid,bigint,text) to service_role;
commit;
