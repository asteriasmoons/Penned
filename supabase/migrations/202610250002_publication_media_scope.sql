begin;
-- A local document may legitimately be published by more than one saved account.
-- Public media URLs already scope every lookup to a publication, not a global ID.
alter table public.penned_publication_media drop constraint penned_publication_media_pkey;
alter table public.penned_publication_media add primary key (publication_id, id);
commit;
