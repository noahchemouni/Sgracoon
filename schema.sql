-- =====================================================================
--  La Racoon Mobile : base de données Supabase
--  À coller en entier dans Supabase > SQL Editor > New query > Run
--  (une seule fois, sur un projet vide)
-- =====================================================================

-- ---------- 1. Tables ----------

-- Un profil par personne (lié au compte de connexion)
create table public.profiles (
  id          uuid primary key references auth.users(id) on delete cascade,
  name        text not null check (char_length(name) between 1 and 60),
  plan        text not null default 'none'
              check (plan in ('none','carnet','mensuel','trimestre')),
  is_driver   boolean not null default false,
  created_at  timestamptz not null default now()
);

-- Réglages (une seule ligne)
create table public.config (
  id        int primary key default 1 check (id = 1),
  seats     int not null default 4 check (seats between 1 and 8),
  price     numeric(6,2) not null default 0.40 check (price >= 0),
  sg_hour   time not null default '20:00'
);
insert into public.config default values;

-- Trajets annoncés par le conducteur (un par jour et par créneau)
create table public.trips (
  id      text primary key,
  date    date not null,
  slot    text not null check (slot in ('0745','1345')),
  going   boolean not null,
  late    boolean not null default false,
  result  jsonb,
  price   numeric(6,2),
  check (id = to_char(date, 'YYYY-MM-DD') || '_' || slot)
);

-- Demandes de place (l'heure de réponse est fixée par le serveur)
create table public.requests (
  trip_id      text not null references public.trips(id) on delete cascade,
  user_id      uuid not null references public.profiles(id) on delete cascade,
  answered_at  timestamptz not null default now(),
  primary key (trip_id, user_id)
);

-- Présence réelle, renseignée par le conducteur
create table public.presence (
  trip_id  text not null references public.trips(id) on delete cascade,
  user_id  uuid not null references public.profiles(id) on delete cascade,
  present  boolean not null,
  primary key (trip_id, user_id)
);

-- ---------- 2. Fonctions ----------

create or replace function public.is_driver() returns boolean
language sql security definer stable set search_path = public as $$
  select coalesce((select p.is_driver from public.profiles p where p.id = auth.uid()), false)
$$;

-- Heure du SG : la veille du trajet, à l'heure choisie, heure de Paris
create or replace function public.sg_time(d date) returns timestamptz
language sql stable set search_path = public as $$
  select ((d - 1) + (select c.sg_hour from public.config c where c.id = 1)) at time zone 'Europe/Paris'
$$;

-- Heure de départ, heure de Paris
create or replace function public.trip_start(d date, s text) returns timestamptz
language sql stable as $$
  select (d + case s when '0745' then time '07:45' else time '13:45' end) at time zone 'Europe/Paris'
$$;

-- Taux de présence d'une personne (null si pas encore d'historique)
create or replace function public.user_rate(u uuid) returns numeric
language sql stable security definer set search_path = public as $$
  select case when count(*) = 0 then null
              else avg(case when x.present then 1.0 else 0.0 end) end
  from public.presence x where x.user_id = u
$$;

-- Le SG : fige les résultats d'un trajet une fois l'heure passée.
-- Ordre : abonnés d'abord, puis réponse la plus rapide, puis meilleur taux de présence.
create or replace function public.freeze_trip(p_id text) returns void
language plpgsql security definer set search_path = public as $$
declare
  t   public.trips%rowtype;
  c   public.config%rowtype;
  ids uuid[];
begin
  select * into t from public.trips where id = p_id for update;
  if not found or not t.going or t.late or t.result is not null then return; end if;
  if now() < public.sg_time(t.date) then return; end if;
  select * into c from public.config where id = 1;

  select coalesce(array_agg(x.user_id order by x.ord), '{}'::uuid[]) into ids from (
    select r.user_id,
           row_number() over (
             order by (p.plan <> 'none') desc,
                      r.answered_at asc,
                      coalesce(public.user_rate(r.user_id), 1) desc,
                      r.user_id
           ) as ord
    from public.requests r
    join public.profiles p on p.id = r.user_id
    where r.trip_id = p_id
  ) x;

  update public.trips
     set result = jsonb_build_object(
           'confirmed', to_jsonb(ids[1:c.seats]),
           'waiting',   to_jsonb(ids[c.seats + 1:cardinality(ids)])),
         price = c.price
   where id = p_id;
end $$;

-- ---------- 3. Garde-fous (triggers) ----------

-- Un passager ne peut ni se donner un abonnement ni se nommer conducteur
create or replace function public.profiles_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is not null and not public.is_driver() then
    if tg_op = 'INSERT' then
      new.plan := 'none';
      new.is_driver := false;
    else
      new.plan := old.plan;
      new.is_driver := old.is_driver;
    end if;
  end if;
  return new;
end $$;
create trigger profiles_guard_trg before insert or update on public.profiles
  for each row execute function public.profiles_guard();

-- Un trajet annoncé après l'heure du SG est marqué "late" (réponses ouvertes jusqu'au départ)
create or replace function public.trips_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.going and new.result is null and (tg_op = 'INSERT' or old.going is distinct from true) then
    new.late := now() >= public.sg_time(new.date);
  end if;
  return new;
end $$;
create trigger trips_guard_trg before insert or update on public.trips
  for each row execute function public.trips_guard();

-- Demandes : seulement tant que le SG n'est pas passé, et l'heure est celle du serveur
create or replace function public.requests_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare t public.trips%rowtype;
begin
  if tg_op = 'DELETE' then
    select * into t from public.trips where id = old.trip_id;
  else
    select * into t from public.trips where id = new.trip_id;
  end if;
  if not found or not t.going then
    raise exception 'Ce trajet n''est pas ouvert aux demandes.';
  end if;
  if t.late then
    if now() >= public.trip_start(t.date, t.slot) then
      raise exception 'Le départ est passé.';
    end if;
  elsif now() >= public.sg_time(t.date) then
    raise exception 'Le SG est passé : les demandes sont closes.';
  end if;
  if tg_op = 'INSERT' then
    new.answered_at := now();
    return new;
  end if;
  return old;
end $$;
create trigger requests_guard_trg before insert or delete on public.requests
  for each row execute function public.requests_guard();

-- ---------- 4. Sécurité des lignes (RLS) ----------

alter table public.profiles enable row level security;
alter table public.config   enable row level security;
alter table public.trips    enable row level security;
alter table public.requests enable row level security;
alter table public.presence enable row level security;

-- Profils : tout le monde (connecté) lit ; chacun crée et modifie le sien ; le conducteur modifie tous
create policy profiles_read   on public.profiles for select to authenticated using (true);
create policy profiles_insert on public.profiles for insert to authenticated with check (id = auth.uid());
create policy profiles_update on public.profiles for update to authenticated
  using (id = auth.uid() or public.is_driver())
  with check (id = auth.uid() or public.is_driver());

-- Réglages : lecture pour tous, modification par le conducteur
create policy config_read   on public.config for select to authenticated using (true);
create policy config_update on public.config for update to authenticated
  using (public.is_driver()) with check (public.is_driver());

-- Trajets : lecture pour tous, annonces par le conducteur
create policy trips_read   on public.trips for select to authenticated using (true);
create policy trips_insert on public.trips for insert to authenticated with check (public.is_driver());
create policy trips_update on public.trips for update to authenticated
  using (public.is_driver()) with check (public.is_driver());

-- Demandes : lecture pour tous ; chacun ajoute et retire les siennes
create policy requests_read   on public.requests for select to authenticated using (true);
create policy requests_insert on public.requests for insert to authenticated with check (user_id = auth.uid());
create policy requests_delete on public.requests for delete to authenticated
  using (user_id = auth.uid() or public.is_driver());

-- Présence : lecture pour tous, saisie par le conducteur
create policy presence_read   on public.presence for select to authenticated using (true);
create policy presence_insert on public.presence for insert to authenticated with check (public.is_driver());
create policy presence_update on public.presence for update to authenticated
  using (public.is_driver()) with check (public.is_driver());
create policy presence_delete on public.presence for delete to authenticated using (public.is_driver());

-- ---------- 5. Mises à jour en direct ----------

alter publication supabase_realtime add table
  public.profiles, public.config, public.trips, public.requests, public.presence;

-- ---------- 6. À FAIRE APRÈS avoir créé ton compte sur le site ----------
-- Remplace l'adresse e-mail par la tienne, puis exécute cette ligne seule :
--
-- update public.profiles set is_driver = true
--  where id = (select id from auth.users where email = 'ton@email.fr');
