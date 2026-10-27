begin;
create function penned_private.assign_short_publication_path()
returns trigger language plpgsql security definer set search_path='' as $$
declare candidate text; bytes bytea; value integer; i integer;
begin
  if new.custom_path is not null then return new; end if;
  loop
    candidate := '';
    while length(candidate) < 8 loop
      bytes := decode(md5(gen_random_uuid()::text), 'hex');
      for i in 0..15 loop
        value := get_byte(bytes,i);
        if value < 252 then
          candidate := candidate || substr('abcdefghijklmnopqrstuvwxyz0123456789',1+value%36,1);
          exit when length(candidate)=8;
        end if;
      end loop;
    end loop;
    perform pg_advisory_xact_lock(hashtextextended('penned-public-path:'||candidate,0));
    if not exists(select 1 from public.penned_publications where custom_path=candidate and id<>new.id) then
      new.custom_path := candidate;
      return new;
    end if;
  end loop;
end $$;
revoke all on function penned_private.assign_short_publication_path() from public,anon,authenticated;
create trigger publication_short_path before insert or update of custom_path,token
on public.penned_publications for each row execute function penned_private.assign_short_publication_path();
-- Preserve existing custom paths and full tokens; only replace the default displayed URL.
update public.penned_publications set custom_path=null,version=version+1,updated_at=now() where custom_path is null;
commit;
