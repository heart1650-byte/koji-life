-- Run once in Supabase SQL Editor AFTER the owner's email has been verified.
-- Never grant this operation to web clients.
do $$
declare owner_id uuid;
begin
 select id into owner_id from auth.users where lower(email)='heart1650@gmail.com' and email_confirmed_at is not null;
 if owner_id is null then raise exception '先に heart1650@gmail.com でメール認証を完了してください';end if;
 insert into public.koji_admins(user_id)values(owner_id)on conflict do nothing;
end$$;
