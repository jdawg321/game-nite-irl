-- Stage 4: in-app account deletion (required by Apple for apps that create accounts).
-- Deletes the caller's auth user. Everything tied to the account goes with it:
-- profile, memberships, roles, positions, location samples and their finds.
-- Games they organized are deleted too, since a game can't exist without its organizer.
-- Audit entries keep the action but lose the person (actor set to null).

create function public.delete_account() returns void
language plpgsql security definer set search_path = '' as $$
declare uid uuid := (select auth.uid());
begin
  if uid is null then raise exception 'Sign in first' using errcode = '42501'; end if;
  delete from public.games where organizer_id = uid;
  delete from auth.users where id = uid;
end $$;

revoke execute on function public.delete_account() from public, anon;
grant execute on function public.delete_account() to authenticated;
