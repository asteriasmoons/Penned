begin;
-- Check the current publication while issuing a grant: a simultaneous password,
-- expiry, unpublish or link change must not produce an already-invalid success.
create or replace function public.penned_reader_session(p_action text,p_publication uuid default null,p_hash text default null,p_epoch bigint default null)
returns jsonb language plpgsql set search_path='' as $$
declare attempts integer; publication public.penned_publications;
begin
  if p_action='limit' then
    delete from penned_private.reader_attempts where window_at<now()-interval '1 day';
    insert into penned_private.reader_attempts(key) values(p_hash)
    on conflict(key) do update set count=case when reader_attempts.window_at<now()-interval '10 minutes' then 1 else reader_attempts.count+1 end,
      window_at=case when reader_attempts.window_at<now()-interval '10 minutes' then now() else reader_attempts.window_at end returning count into attempts;
    return jsonb_build_object('allowed',attempts<=least(500,coalesce(p_epoch,20)));
  elsif p_action='grant' then
    select * into publication from public.penned_publications where id=p_publication for share;
    if not found or not publication.active or publication.access_epoch<>p_epoch
      or (publication.settings->>'expiresAt' is not null and (publication.settings->>'expiresAt')::timestamptz<=now()) then
      raise exception 'publishing_conflict';
    end if;
    delete from penned_private.reader_grants where expires_at<now();
    insert into penned_private.reader_grants(hash,publication_id,epoch) values(p_hash,p_publication,p_epoch);
    return jsonb_build_object('allowed',true);
  elsif p_action='verify' then
    return jsonb_build_object('allowed',exists(select 1 from penned_private.reader_grants where hash=p_hash and publication_id=p_publication and epoch=p_epoch and expires_at>now()));
  end if;
  raise exception 'publishing_invalid_action';
end $$;
commit;
