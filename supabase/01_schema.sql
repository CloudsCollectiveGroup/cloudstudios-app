-- =====================================================================
-- CloudStudios Studio-App · 01_schema.sql
-- Tabellen, Zugriffsregeln, Buchungslogik. Im Supabase-SQL-Editor ausführen.
-- Grundsatz: Niemand schreibt direkt in die Tabellen. Alles läuft über die
-- Funktionen unten; sie prüfen Rolle, Guthaben, Fristen und Belegung.
-- =====================================================================
create schema if not exists extensions;
create extension if not exists btree_gist with schema extensions;

-- ---------------------------------------------------------------------
-- Stammdaten
-- ---------------------------------------------------------------------
create table if not exists studios (
  id               text primary key,               -- s1, s3, s4, s5
  name             text not null,
  credits_pro_std  numeric(4,2) not null check (credits_pro_std > 0),
  partner          text check (partner in ('basement','blackclouds')),
  partner_eur_std  numeric(6,2),                   -- Festbetrag je Stunde (BlackClouds)
  partner_eur_credit numeric(6,2),                 -- je CloudStudios-Credit (Basement)
  selbst_buchbar   boolean not null default true,  -- Studio 5: false (nur auf Anfrage)
  aktiv            boolean not null default true,
  reihenfolge      int not null default 0
);

insert into studios (id,name,credits_pro_std,partner,partner_eur_std,partner_eur_credit,selbst_buchbar,reihenfolge) values
  ('s1','Studio 1',1,null,null,null,true,1),
  ('s3','Studio 3 · Basement Studios',1,'basement',null,5,true,3),
  ('s4','Studio 4 · BlackClouds',2,'blackclouds',14,null,true,4),
  ('s5','Studio 5 · BlackClouds Premium',4.5,'blackclouds',35,null,false,5)
on conflict (id) do nothing;

create table if not exists profiles (
  id         uuid primary key references auth.users(id) on delete cascade,
  rolle      text not null default 'kunde' check (rolle in ('admin','team','partner','kunde')),
  partner    text check (partner in ('basement','blackclouds')),
  kn         text unique,                          -- KN-0xx (Kunden)
  name       text not null,
  telefon    text,
  aktiv      boolean not null default true,
  erstellt_am timestamptz not null default now(),
  check (rolle <> 'partner' or partner is not null)
);

-- Mitgliedschaften und Pauschalen (Monatsguthaben)
create table if not exists mitgliedschaften (
  id             bigserial primary key,
  kunde          uuid not null references profiles(id),
  tarif          text not null,                    -- z. B. 'PA 202 M', 'Basement 40'
  credits_monat  numeric(6,2) not null check (credits_monat > 0),
  nur_studios    text[],                           -- null = alle selbst buchbaren; F&F: {s1}; Basement: {s3}
  beitrag_brutto numeric(8,2) not null default 0,
  basement_pauschale boolean not null default false, -- Beitrag wird 50/50 mit Basement geteilt
  aktiv_ab       date not null,
  aktiv_bis      date,
  vn             text
);

-- ---------------------------------------------------------------------
-- Credits: jeder Zugang ist ein "Posten" mit eigener Gültigkeit
-- ---------------------------------------------------------------------
create table if not exists credit_posten (
  id          bigserial primary key,
  kunde       uuid not null references profiles(id),
  art         text not null check (art in ('paket','bonus','mitglied','label','basement','korrektur')),
  credits     numeric(7,2) not null check (credits > 0),
  gueltig_ab  date not null,
  gueltig_bis date not null,
  nur_studios text[],                              -- Einschränkung, null = keine
  rechnung    text,                                -- RN-CS-xxx
  mitgliedschaft bigint references mitgliedschaften(id),
  monat       date,                                -- bei Monatsguthaben: 1. des Monats
  notiz       text,
  erstellt_von uuid references profiles(id),
  erstellt_am timestamptz not null default now(),
  check (gueltig_bis >= gueltig_ab),
  unique (mitgliedschaft, monat)                   -- Monatslauf kann nie doppelt buchen
);

-- ---------------------------------------------------------------------
-- Kalender
-- ---------------------------------------------------------------------
create table if not exists buchungen (
  id            bigserial primary key,
  studio        text not null references studios(id),
  zeitraum      tstzrange not null,
  status        text not null check (status in ('angefragt','gebucht','geschlossen','blockiert','storniert','verfallen')),
  kunde         uuid references profiles(id),      -- null bei Walk-In ohne Konto / Blockierung
  gast_name     text,                              -- Walk-In ohne Konto
  kn            text,
  credits       numeric(7,2) not null default 0,   -- abgezogene Credits
  preis_brutto  numeric(8,2),                      -- Walk-In in Euro
  reserviert_bis timestamptz,                      -- nur 'angefragt'
  angebot       text,                              -- AN-CS-xxx
  rechnung      text,                              -- RN-CS-xxx
  erstattet     boolean not null default false,    -- Credits zurückgegeben
  grund         text,                              -- Blockierung / geschlossene Gesellschaft
  eigennutzung_partner text,                       -- 'basement' / 'blackclouds'
  notiz         text,
  erstellt_von  uuid references profiles(id),
  erstellt_am   timestamptz not null default now(),
  storniert_von uuid references profiles(id),
  storniert_am  timestamptz,
  check (lower(zeitraum) < upper(zeitraum)),
  -- Doppelbuchungen sind technisch ausgeschlossen:
  constraint keine_ueberschneidung exclude using gist (studio with =, zeitraum with &&)
    where (status in ('angefragt','gebucht','geschlossen','blockiert'))
);
create index if not exists buchungen_kunde on buchungen(kunde);
create index if not exists buchungen_zeit on buchungen using gist (zeitraum);

-- Welche Credits aus welchem Posten für eine Buchung genommen wurden
create table if not exists zuordnungen (
  buchung  bigint not null references buchungen(id),
  posten   bigint not null references credit_posten(id),
  credits  numeric(7,2) not null check (credits > 0),
  primary key (buchung, posten)
);

-- Kontobewegungen: Kauf, Buchung, Storno, Verfall, Korrektur (nur anhängen)
create table if not exists bewegungen (
  id        bigserial primary key,
  kunde     uuid not null references profiles(id),
  art       text not null check (art in ('kauf','buchung','storno','verfall','korrektur')),
  credits   numeric(7,2) not null,               -- + Zugang, − Abgang
  posten    bigint references credit_posten(id),
  buchung   bigint references buchungen(id),
  notiz     text,
  von       uuid references profiles(id),
  am        timestamptz not null default now()
);
create index if not exists bewegungen_kunde on bewegungen(kunde);
create unique index if not exists verfall_einmal on bewegungen(posten) where art = 'verfall';

-- Verfallsbeträge je Posten (für die Restberechnung)
-- Protokoll aller Aktionen (wer, wann, was)
create table if not exists protokoll (
  id      bigserial primary key,
  von     uuid,
  am      timestamptz not null default now(),
  aktion  text not null,
  details jsonb
);

-- Anfragen für Studio 5 und Sonderwünsche (kein Slot, nur Nachricht ans Team)
create table if not exists anfragen (
  id        bigserial primary key,
  kunde     uuid references profiles(id),
  studio    text references studios(id),
  wunsch    text not null,
  status    text not null default 'offen' check (status in ('offen','in_klaerung','erledigt','abgelehnt')),
  erstellt_am timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- Hilfsfunktionen
-- ---------------------------------------------------------------------
create or replace function meine_rolle() returns text
language sql stable security definer set search_path = public as
$$ select rolle from profiles where id = auth.uid() and aktiv $$;

create or replace function ist_team() returns boolean
language sql stable security definer set search_path = public as
$$ select coalesce(meine_rolle() in ('admin','team'), false) $$;

create or replace function mein_partner() returns text
language sql stable security definer set search_path = public as
$$ select partner from profiles where id = auth.uid() and aktiv and rolle = 'partner' $$;

create or replace function berlin_datum(ts timestamptz) returns date
language sql immutable as $$ select (ts at time zone 'Europe/Berlin')::date $$;

create or replace function monatsende(d date) returns date
language sql immutable as $$ select (date_trunc('month', d) + interval '1 month - 1 day')::date $$;

create or replace function log_aktion(p_aktion text, p_details jsonb) returns void
language sql security definer set search_path = public as
$$ insert into protokoll(von, aktion, details) values (auth.uid(), p_aktion, p_details) $$;

-- Rest eines Postens = Credits − aktive Zuordnungen − Verfall
create or replace function posten_rest(p_posten bigint) returns numeric
language sql stable security definer set search_path = public as $$
  select p.credits
       - coalesce((select sum(z.credits) from zuordnungen z join buchungen b on b.id = z.buchung
                   where z.posten = p.id and not b.erstattet), 0)
       - coalesce((select -sum(v.credits) from bewegungen v where v.posten = p.id
                   and v.art in ('verfall','korrektur') and v.credits < 0), 0)
  from credit_posten p where p.id = p_posten
$$;

-- Abgelaufene 'angefragt'-Slots freigeben (wird auch vor jeder Buchung ausgeführt)
create or replace function anfragen_verfallen_lassen() returns int
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  update buchungen set status = 'verfallen'
   where status = 'angefragt' and reserviert_bis < now();
  get diagnostics n = row_count;
  return n;
end $$;

-- Credits, die für einen Termin in einem Studio nutzbar sind (älteste zuerst)
create or replace function nutzbare_posten(p_kunde uuid, p_studio text, p_tag date)
returns table(posten bigint, rest numeric, gueltig_bis date)
language sql stable security definer set search_path = public as $$
  select p.id, posten_rest(p.id), p.gueltig_bis
    from credit_posten p
   where p.kunde = p_kunde
     and p.gueltig_ab <= p_tag and p.gueltig_bis >= p_tag
     and (p.nur_studios is null or p_studio = any(p.nur_studios))
     and posten_rest(p.id) > 0
   order by p.gueltig_bis, p.id
$$;

-- ---------------------------------------------------------------------
-- Buchen mit Credits (Kunde selbst oder Team für Kunden)
-- Fehlercodes: NICHT_ANGEMELDET, KEIN_ZUGRIFF, MINDESTENS_2_STUNDEN,
-- UNGUELTIGE_DAUER, VERGANGENHEIT, NUR_AUF_ANFRAGE, STUDIO_INAKTIV,
-- ZU_WENIG_CREDITS:<maximal buchbare Stunden>, SLOT_BELEGT
-- ---------------------------------------------------------------------
create or replace function credits_buchen(p_studio text, p_start timestamptz, p_stunden numeric, p_kunde uuid default null, p_notiz text default null)
returns bigint
language plpgsql security definer set search_path = public as $$
declare
  v_rolle text := meine_rolle();
  v_kunde uuid;
  v_st studios;
  v_bedarf numeric; v_offen numeric; v_nimm numeric; v_verfuegbar numeric;
  v_tag date; v_id bigint; r record;
begin
  if v_rolle is null then raise exception 'NICHT_ANGEMELDET'; end if;
  if v_rolle = 'kunde' then
    if p_kunde is not null and p_kunde <> auth.uid() then raise exception 'KEIN_ZUGRIFF'; end if;
    v_kunde := auth.uid();
  elsif v_rolle in ('admin','team') then
    if p_kunde is null then raise exception 'KUNDE_FEHLT'; end if;
    v_kunde := p_kunde;
  else
    raise exception 'KEIN_ZUGRIFF';
  end if;

  select * into v_st from studios where id = p_studio;
  if not found or not v_st.aktiv then raise exception 'STUDIO_INAKTIV'; end if;
  if v_rolle = 'kunde' and not v_st.selbst_buchbar then raise exception 'NUR_AUF_ANFRAGE'; end if;
  if p_stunden < 2 then raise exception 'MINDESTENS_2_STUNDEN'; end if;
  if p_stunden > 24 or (p_stunden * 2) <> floor(p_stunden * 2) then raise exception 'UNGUELTIGE_DAUER'; end if;
  if p_start < now() then raise exception 'VERGANGENHEIT'; end if;

  -- Pro Kunde nacheinander buchen, damit dasselbe Guthaben nie doppelt verwendet wird
  perform pg_advisory_xact_lock(hashtext('konto:' || v_kunde::text));
  perform anfragen_verfallen_lassen();

  v_tag := berlin_datum(p_start + make_interval(mins => (p_stunden * 60)::int) - interval '1 second');
  -- Credits müssen am Ende des Termins noch gültig sein; Beginn-Tag muss im Gültigkeitszeitraum liegen
  v_bedarf := round(p_stunden * v_st.credits_pro_std, 2);

  select coalesce(sum(n.rest),0) into v_verfuegbar
    from nutzbare_posten(v_kunde, p_studio, v_tag) n
    join credit_posten p on p.id = n.posten
   where p.gueltig_ab <= berlin_datum(p_start);
  if v_verfuegbar < v_bedarf then
    raise exception 'ZU_WENIG_CREDITS:%', trim_scale(floor(v_verfuegbar / v_st.credits_pro_std * 2) / 2);
  end if;

  begin
    insert into buchungen(studio, zeitraum, status, kunde, kn, credits, erstellt_von, notiz)
    select p_studio, tstzrange(p_start, p_start + make_interval(mins => (p_stunden * 60)::int), '[)'),
           'gebucht', v_kunde, pr.kn, v_bedarf, auth.uid(), p_notiz
      from profiles pr where pr.id = v_kunde
    returning id into v_id;
  exception when exclusion_violation then
    raise exception 'SLOT_BELEGT';
  end;

  v_offen := v_bedarf;
  for r in select n.* from nutzbare_posten(v_kunde, p_studio, v_tag) n
             join credit_posten p on p.id = n.posten
            where p.gueltig_ab <= berlin_datum(p_start) loop
    exit when v_offen <= 0;
    v_nimm := least(r.rest, v_offen);
    insert into zuordnungen(buchung, posten, credits) values (v_id, r.posten, v_nimm);
    v_offen := v_offen - v_nimm;
  end loop;

  insert into bewegungen(kunde, art, credits, buchung, von, notiz)
  values (v_kunde, 'buchung', -v_bedarf, v_id, auth.uid(), v_st.name || ', ' || p_stunden || ' Std.');
  perform log_aktion('credits_buchen', jsonb_build_object('buchung', v_id, 'studio', p_studio, 'start', p_start, 'stunden', p_stunden, 'credits', v_bedarf));
  return v_id;
end $$;

-- Wie viele Stunden kann der Kunde für diesen Termin höchstens buchen? (für den Vorschlag in der App)
create or replace function max_stunden(p_studio text, p_start timestamptz, p_kunde uuid default null)
returns numeric
language plpgsql stable security definer set search_path = public as $$
declare v_kunde uuid := case when ist_team() then p_kunde else auth.uid() end;
        v_cph numeric; v_sum numeric;
begin
  if v_kunde is null then return 0; end if;
  select credits_pro_std into v_cph from studios where id = p_studio;
  select coalesce(sum(n.rest),0) into v_sum
    from nutzbare_posten(v_kunde, p_studio, berlin_datum(p_start)) n;
  return trim_scale(floor(v_sum / v_cph * 2) / 2);
end $$;

-- ---------------------------------------------------------------------
-- Stornieren: mehr als 24 Std. vorher → Credits zurück, sonst bleiben sie abgezogen.
-- Admin kann mit p_kulanz trotzdem erstatten.
-- ---------------------------------------------------------------------
create or replace function stornieren(p_buchung bigint, p_kulanz boolean default false)
returns text
language plpgsql security definer set search_path = public as $$
declare v_rolle text := meine_rolle(); b buchungen; v_erstatten boolean;
begin
  if v_rolle is null then raise exception 'NICHT_ANGEMELDET'; end if;
  select * into b from buchungen where id = p_buchung for update;
  if not found then raise exception 'NICHT_GEFUNDEN'; end if;
  if v_rolle = 'kunde' and b.kunde is distinct from auth.uid() then raise exception 'KEIN_ZUGRIFF'; end if;
  if v_rolle = 'partner' and not (b.status = 'blockiert' and b.eigennutzung_partner = mein_partner()) then raise exception 'KEIN_ZUGRIFF'; end if;
  if b.status not in ('angefragt','gebucht','geschlossen','blockiert') then raise exception 'NICHT_STORNIERBAR'; end if;
  if lower(b.zeitraum) <= now() and v_rolle <> 'admin' then raise exception 'BEREITS_BEGONNEN'; end if;
  if p_kulanz and v_rolle <> 'admin' then raise exception 'KEIN_ZUGRIFF'; end if;

  v_erstatten := b.credits > 0 and (lower(b.zeitraum) - now() > interval '24 hours' or p_kulanz);

  update buchungen set status = 'storniert', storniert_von = auth.uid(), storniert_am = now(),
                       erstattet = v_erstatten
   where id = p_buchung;

  if v_erstatten then
    insert into bewegungen(kunde, art, credits, buchung, von, notiz)
    values (b.kunde, 'storno', b.credits, b.id, auth.uid(), case when p_kulanz then 'Kulanz' else 'Storno > 24 Std.' end);
  end if;
  perform log_aktion('stornieren', jsonb_build_object('buchung', p_buchung, 'erstattet', v_erstatten, 'kulanz', p_kulanz));
  return case when v_erstatten then 'ERSTATTET' when b.credits > 0 then 'NICHT_ERSTATTET' else 'STORNIERT' end;
end $$;

-- ---------------------------------------------------------------------
-- Team: Walk-In-Anfrage (grün), Zahlung bestätigen (blau)
-- ---------------------------------------------------------------------
create or replace function anfrage_eintragen(p_studio text, p_start timestamptz, p_stunden numeric,
  p_gast_name text, p_kn text default null, p_kunde uuid default null, p_preis_brutto numeric default null,
  p_angebot text default null, p_notiz text default null)
returns bigint
language plpgsql security definer set search_path = public as $$
declare v_id bigint;
begin
  if not ist_team() then raise exception 'KEIN_ZUGRIFF'; end if;
  if p_stunden <= 0 or (p_stunden * 2) <> floor(p_stunden * 2) then raise exception 'UNGUELTIGE_DAUER'; end if;
  perform anfragen_verfallen_lassen();
  begin
    insert into buchungen(studio, zeitraum, status, kunde, gast_name, kn, preis_brutto, angebot,
                          reserviert_bis, erstellt_von, notiz)
    values (p_studio, tstzrange(p_start, p_start + make_interval(mins => (p_stunden*60)::int), '[)'),
            'angefragt', p_kunde, p_gast_name, p_kn, p_preis_brutto, p_angebot,
            least(greatest(p_start - interval '24 hours', now() + interval '1 hour'), p_start), auth.uid(), p_notiz)
    returning id into v_id;
  exception when exclusion_violation then raise exception 'SLOT_BELEGT';
  end;
  perform log_aktion('anfrage_eintragen', jsonb_build_object('buchung', v_id, 'studio', p_studio, 'start', p_start));
  return v_id;
end $$;

create or replace function zahlung_bestaetigen(p_buchung bigint, p_rechnung text default null)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if not ist_team() then raise exception 'KEIN_ZUGRIFF'; end if;
  update buchungen set status = 'gebucht', rechnung = coalesce(p_rechnung, rechnung), reserviert_bis = null
   where id = p_buchung and status = 'angefragt';
  if not found then raise exception 'NICHT_ANGEFRAGT'; end if;
  perform log_aktion('zahlung_bestaetigen', jsonb_build_object('buchung', p_buchung, 'rechnung', p_rechnung));
end $$;

-- ---------------------------------------------------------------------
-- Blockieren (grau) und geschlossene Gesellschaft (rot)
-- Team: alle Studios. Partner: nur eigene Studios, nur Eigennutzung.
-- ---------------------------------------------------------------------
create or replace function blockieren(p_studio text, p_start timestamptz, p_ende timestamptz,
  p_grund text, p_geschlossen boolean default false)
returns bigint
language plpgsql security definer set search_path = public as $$
declare v_rolle text := meine_rolle(); v_partner text; v_id bigint;
begin
  if v_rolle in ('admin','team') then
    null;
  elsif v_rolle = 'partner' then
    if p_geschlossen then raise exception 'KEIN_ZUGRIFF'; end if;
    select partner into v_partner from studios where id = p_studio;
    if v_partner is distinct from mein_partner() then raise exception 'KEIN_ZUGRIFF'; end if;
  else
    raise exception 'KEIN_ZUGRIFF';
  end if;
  perform anfragen_verfallen_lassen();
  begin
    insert into buchungen(studio, zeitraum, status, grund, eigennutzung_partner, erstellt_von)
    values (p_studio, tstzrange(p_start, p_ende, '[)'),
            case when p_geschlossen then 'geschlossen' else 'blockiert' end,
            p_grund, case when v_rolle = 'partner' then mein_partner() end, auth.uid())
    returning id into v_id;
  exception when exclusion_violation then raise exception 'SLOT_BELEGT';
  end;
  perform log_aktion('blockieren', jsonb_build_object('buchung', v_id, 'studio', p_studio, 'geschlossen', p_geschlossen));
  return v_id;
end $$;

-- ---------------------------------------------------------------------
-- Credits aufladen (Team, nach Zahlungseingang) und Korrektur (nur Admin)
-- ---------------------------------------------------------------------
create or replace function credits_aufladen(p_kunde uuid, p_art text, p_credits numeric,
  p_rechnung text default null, p_zahlungsdatum date default null, p_notiz text default null)
returns bigint
language plpgsql security definer set search_path = public as $$
declare v_ab date := coalesce(p_zahlungsdatum, berlin_datum(now())); v_bis date; v_nur text[]; v_id bigint;
begin
  if not ist_team() then raise exception 'KEIN_ZUGRIFF'; end if;
  if p_art not in ('paket','bonus','label','basement') then raise exception 'UNGUELTIGE_ART'; end if;
  if p_credits <= 0 then raise exception 'UNGUELTIGE_MENGE'; end if;
  if p_art = 'paket' and p_rechnung is null then raise exception 'RECHNUNG_FEHLT'; end if;
  case p_art
    when 'paket'    then v_bis := (v_ab + interval '3 months' - interval '1 day')::date; v_nur := null;
    when 'bonus'    then v_bis := (v_ab + interval '3 months' - interval '1 day')::date; v_nur := array['s1','s3'];
    when 'label'    then v_bis := monatsende(v_ab); v_nur := array['s1'];
    when 'basement' then v_bis := monatsende(v_ab); v_nur := array['s3'];
  end case;
  insert into credit_posten(kunde, art, credits, gueltig_ab, gueltig_bis, nur_studios, rechnung, notiz, erstellt_von)
  values (p_kunde, p_art, p_credits, v_ab, v_bis, v_nur, p_rechnung, p_notiz, auth.uid())
  returning id into v_id;
  insert into bewegungen(kunde, art, credits, posten, von, notiz)
  values (p_kunde, 'kauf', p_credits, v_id, auth.uid(), p_art || coalesce(' · ' || p_rechnung, ''));
  perform log_aktion('credits_aufladen', jsonb_build_object('posten', v_id, 'kunde', p_kunde, 'art', p_art, 'credits', p_credits));
  return v_id;
end $$;

create or replace function korrektur(p_kunde uuid, p_credits numeric, p_notiz text, p_gueltig_bis date default null)
returns void
language plpgsql security definer set search_path = public as $$
declare v_id bigint; v_offen numeric; v_nimm numeric; r record;
begin
  if meine_rolle() <> 'admin' then raise exception 'KEIN_ZUGRIFF'; end if;
  if p_notiz is null or length(trim(p_notiz)) < 3 then raise exception 'BEGRUENDUNG_FEHLT'; end if;
  if p_credits > 0 then
    insert into credit_posten(kunde, art, credits, gueltig_ab, gueltig_bis, notiz, erstellt_von)
    values (p_kunde, 'korrektur', p_credits, berlin_datum(now()),
            coalesce(p_gueltig_bis, (berlin_datum(now()) + interval '3 months' - interval '1 day')::date), p_notiz, auth.uid())
    returning id into v_id;
    insert into bewegungen(kunde, art, credits, posten, von, notiz) values (p_kunde, 'korrektur', p_credits, v_id, auth.uid(), p_notiz);
  elsif p_credits < 0 then
    -- Abzug als Verfall der ältesten Posten
    v_offen := -p_credits;
    for r in select n.* from nutzbare_posten(p_kunde, 's1', berlin_datum(now())) n
             union select n.* from nutzbare_posten(p_kunde, 's3', berlin_datum(now())) n
             order by 3, 1 loop
      exit when v_offen <= 0;
      v_nimm := least(posten_rest(r.posten), v_offen);
      continue when v_nimm <= 0;
      insert into bewegungen(kunde, art, credits, posten, von, notiz) values (p_kunde, 'korrektur', -v_nimm, r.posten, auth.uid(), p_notiz);
      v_offen := v_offen - v_nimm;
    end loop;
    if v_offen > 0 then raise exception 'ZU_WENIG_CREDITS'; end if;
  end if;
  perform log_aktion('korrektur', jsonb_build_object('kunde', p_kunde, 'credits', p_credits, 'notiz', p_notiz));
end $$;

-- ---------------------------------------------------------------------
-- Täglich: abgelaufene Reste verfallen lassen. Monatlich: Mitglieder-Credits.
-- (In Supabase per pg_cron, siehe unten; auch von Hand aufrufbar.)
-- ---------------------------------------------------------------------
create or replace function verfall_buchen() returns int
language plpgsql security definer set search_path = public as $$
declare r record; n int := 0; v_rest numeric;
begin
  if auth.uid() is not null and not ist_team() then raise exception 'KEIN_ZUGRIFF'; end if;
  for r in select p.* from credit_posten p
            where p.gueltig_bis < berlin_datum(now())
              and not exists (select 1 from bewegungen v where v.posten = p.id and v.art = 'verfall') loop
    v_rest := posten_rest(r.id);
    if v_rest > 0 then
      insert into bewegungen(kunde, art, credits, posten, notiz) values (r.kunde, 'verfall', -v_rest, r.id, 'abgelaufen am ' || to_char(r.gueltig_bis, 'DD.MM.YYYY'));
      n := n + 1;
    end if;
  end loop;
  return n;
end $$;

create or replace function mitglieder_monatslauf(p_monat date default null) returns int
language plpgsql security definer set search_path = public as $$
declare v_monat date := date_trunc('month', coalesce(p_monat, berlin_datum(now())))::date; r record; v_id bigint; n int := 0;
begin
  if auth.uid() is not null and not ist_team() then raise exception 'KEIN_ZUGRIFF'; end if;
  for r in select m.* from mitgliedschaften m
            where m.aktiv_ab <= monatsende(v_monat) and (m.aktiv_bis is null or m.aktiv_bis >= v_monat) loop
    insert into credit_posten(kunde, art, credits, gueltig_ab, gueltig_bis, nur_studios, mitgliedschaft, monat, notiz)
    values (r.kunde, case when r.basement_pauschale then 'basement' else 'mitglied' end, r.credits_monat,
            greatest(v_monat, r.aktiv_ab), monatsende(v_monat), r.nur_studios, r.id, v_monat, r.tarif)
    on conflict (mitgliedschaft, monat) do nothing
    returning id into v_id;
    if v_id is not null then
      insert into bewegungen(kunde, art, credits, posten, notiz) values (r.kunde, 'kauf', r.credits_monat, v_id, r.tarif || ' · ' || to_char(v_monat, 'MM/YYYY'));
      n := n + 1;
    end if;
    v_id := null;
  end loop;
  return n;
end $$;

-- ---------------------------------------------------------------------
-- Lesen: Konto, Kalender, Partner-Abrechnung
-- ---------------------------------------------------------------------
create or replace function konto(p_kunde uuid default null)
returns table(verfuegbar numeric, reserviert numeric, naechster_ablauf date, credits_ablaufend numeric)
language plpgsql stable security definer set search_path = public as $$
declare v_kunde uuid := case when ist_team() and p_kunde is not null then p_kunde else auth.uid() end;
begin
  return query
  with rest as (
    select p.id, p.gueltig_bis, posten_rest(p.id) as r
      from credit_posten p where p.kunde = v_kunde and p.gueltig_bis >= berlin_datum(now())
  )
  select coalesce((select sum(r) from rest), 0),
         coalesce((select sum(b.credits) from buchungen b where b.kunde = v_kunde and b.status = 'gebucht'
                     and not b.erstattet and lower(b.zeitraum) > now()), 0),
         (select min(gueltig_bis) from rest where r > 0),
         coalesce((select sum(r) from rest where gueltig_bis = (select min(gueltig_bis) from rest where r > 0)), 0);
end $$;

create or replace function kalender(p_von timestamptz, p_bis timestamptz)
returns table(id bigint, studio text, beginn timestamptz, ende timestamptz, farbe text, titel text, eigene boolean, status text)
language plpgsql stable security definer set search_path = public as $$
declare v_rolle text := meine_rolle(); v_partner text := mein_partner();
begin
  if v_rolle is null then raise exception 'NICHT_ANGEMELDET'; end if;
  return query
  select b.id, b.studio, lower(b.zeitraum), upper(b.zeitraum),
         case b.status
           when 'angefragt' then 'gruen'
           when 'geschlossen' then 'rot'
           when 'blockiert' then 'grau'
           else case when exists (select 1 from mitgliedschaften m where m.kunde = b.kunde
                                   and m.aktiv_ab <= berlin_datum(lower(b.zeitraum))
                                   and (m.aktiv_bis is null or m.aktiv_bis >= berlin_datum(lower(b.zeitraum))))
                     then 'lila' else 'blau' end
         end,
         case
           when v_rolle in ('admin','team') then coalesce(pr.name, b.gast_name, b.grund, 'Blockiert') || coalesce(' · ' || coalesce(pr.kn, b.kn), '')
           when b.kunde = auth.uid() then 'Ihre Buchung'
           when v_rolle = 'partner' and b.eigennutzung_partner = v_partner then coalesce(b.grund, 'Eigennutzung')
           else 'Belegt'
         end,
         b.kunde = auth.uid(),
         case when v_rolle in ('admin','team') or b.kunde = auth.uid() then b.status else 'belegt' end
    from buchungen b
    left join profiles pr on pr.id = b.kunde
    join studios s on s.id = b.studio
   where b.status in ('angefragt','gebucht','geschlossen','blockiert')
     and b.zeitraum && tstzrange(p_von, p_bis, '[)')
     and (v_rolle <> 'partner' or s.partner = v_partner)
     and (b.status <> 'angefragt' or b.reserviert_bis >= now())
   order by lower(b.zeitraum);
end $$;

-- Partner-Abrechnung je Monat. BlackClouds: Festbetrag je genutzter Stunde.
-- Basement: 5 € je CloudStudios-Credit in Studio 3 + 50 % netto der Basement-Pauschalen.
-- Gezählt werden Buchungen mit Termin im Monat, nicht erstattet (späte Stornos zählen wie genutzt).
create or replace function partner_abrechnung(p_monat date, p_partner text default null)
returns table(partner text, posten text, menge numeric, betrag numeric)
language plpgsql stable security definer set search_path = public as $$
declare v_von date := date_trunc('month', p_monat)::date; v_bis date := monatsende(p_monat);
        v_partner text := case when meine_rolle() = 'admin' then p_partner else mein_partner() end;
begin
  if meine_rolle() not in ('admin','partner') then raise exception 'KEIN_ZUGRIFF'; end if;
  return query
  -- BlackClouds: Stunden aller gebuchten, nicht erstatteten Termine (Credits und Walk-In)
  select s.partner, s.name || ' · Stunden', round(sum(extract(epoch from upper(b.zeitraum) - lower(b.zeitraum)) / 3600)::numeric, 2),
         round(sum(extract(epoch from upper(b.zeitraum) - lower(b.zeitraum)) / 3600)::numeric * s.partner_eur_std, 2)
    from buchungen b join studios s on s.id = b.studio
   where s.partner_eur_std is not null and b.status in ('gebucht','storniert') and not b.erstattet
     and (b.status = 'gebucht' or b.credits > 0)
     and berlin_datum(lower(b.zeitraum)) between v_von and v_bis
     and (v_partner is null or s.partner = v_partner)
   group by s.partner, s.name, s.partner_eur_std
  union all
  -- Basement: CloudStudios-Credits in Studio 3 (ohne Basement-Credits)
  select 'basement', 'Studio 3 · CloudStudios-Credits', coalesce(sum(z.credits),0), coalesce(sum(z.credits),0) * 5
    from zuordnungen z join buchungen b on b.id = z.buchung join credit_posten p on p.id = z.posten
   where b.studio = 's3' and not b.erstattet and p.art <> 'basement'
     and berlin_datum(lower(b.zeitraum)) between v_von and v_bis
  having (v_partner is null or v_partner = 'basement')
  union all
  -- Basement: Walk-In in Studio 3, 50 % vom Netto
  select 'basement', 'Studio 3 · Walk-In (50 % netto)', count(*)::numeric, round(coalesce(sum(b.preis_brutto),0) / 1.19 / 2, 2)
    from buchungen b
   where b.studio = 's3' and b.status = 'gebucht' and b.credits = 0 and b.preis_brutto is not null
     and berlin_datum(lower(b.zeitraum)) between v_von and v_bis
  having (v_partner is null or v_partner = 'basement')
  union all
  -- Basement-Pauschalen: 50 % vom Netto-Beitrag
  select 'basement', 'Basement-Pauschalen (50 % netto)', count(*)::numeric, round(coalesce(sum(m.beitrag_brutto),0) / 1.19 / 2, 2)
    from mitgliedschaften m
   where m.basement_pauschale and m.aktiv_ab <= v_bis and (m.aktiv_bis is null or m.aktiv_bis >= v_von)
  having (v_partner is null or v_partner = 'basement');
end $$;

-- Studio-5-Anfrage durch Kunden
create or replace function anfrage_senden(p_studio text, p_wunsch text) returns bigint
language plpgsql security definer set search_path = public as $$
declare v_id bigint;
begin
  if meine_rolle() is null then raise exception 'NICHT_ANGEMELDET'; end if;
  insert into anfragen(kunde, studio, wunsch) values (auth.uid(), p_studio, p_wunsch) returning id into v_id;
  perform log_aktion('anfrage_senden', jsonb_build_object('anfrage', v_id, 'studio', p_studio));
  return v_id;
end $$;


-- ---------------------------------------------------------------------
-- Konten: Neuer Supabase-Benutzer → Profil (Rolle Kunde). Rollen setzt nur der Admin.
-- ---------------------------------------------------------------------
create or replace function neuer_benutzer() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into profiles(id, name, kn)
  values (new.id, coalesce(new.raw_user_meta_data->>'name', split_part(new.email, '@', 1)),
          nullif(new.raw_user_meta_data->>'kn', ''))
  on conflict (id) do nothing;
  return new;
end $$;
drop trigger if exists bei_neuem_benutzer on auth.users;
create trigger bei_neuem_benutzer after insert on auth.users for each row execute function neuer_benutzer();

create or replace function profil_setzen(p_id uuid, p_name text default null, p_kn text default null,
  p_rolle text default null, p_partner text default null, p_aktiv boolean default null) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not ist_team() then raise exception 'KEIN_ZUGRIFF'; end if;
  if (p_rolle is not null or p_partner is not null) and meine_rolle() <> 'admin' then raise exception 'KEIN_ZUGRIFF'; end if;
  update profiles set name = coalesce(p_name, name), kn = coalesce(p_kn, kn),
                      rolle = coalesce(p_rolle, rolle), partner = coalesce(p_partner, partner),
                      aktiv = coalesce(p_aktiv, aktiv)
   where id = p_id;
  if not found then raise exception 'NICHT_GEFUNDEN'; end if;
  perform log_aktion('profil_setzen', jsonb_build_object('profil', p_id, 'rolle', p_rolle, 'partner', p_partner, 'aktiv', p_aktiv));
end $$;

-- ---------------------------------------------------------------------
-- Zugriffsregeln (RLS): Lesen nur, was einem zusteht. Schreiben nur über Funktionen.
-- ---------------------------------------------------------------------
alter table studios enable row level security;
alter table profiles enable row level security;
alter table mitgliedschaften enable row level security;
alter table credit_posten enable row level security;
alter table buchungen enable row level security;
alter table zuordnungen enable row level security;
alter table bewegungen enable row level security;
alter table protokoll enable row level security;
alter table anfragen enable row level security;

drop policy if exists studios_lesen on studios;
create policy studios_lesen on studios for select to authenticated using (true);
drop policy if exists profiles_lesen on profiles;
create policy profiles_lesen on profiles for select to authenticated using (id = auth.uid() or ist_team());
drop policy if exists mitglied_lesen on mitgliedschaften;
create policy mitglied_lesen on mitgliedschaften for select to authenticated using (kunde = auth.uid() or ist_team());
drop policy if exists posten_lesen on credit_posten;
create policy posten_lesen on credit_posten for select to authenticated using (kunde = auth.uid() or ist_team());
drop policy if exists buchungen_lesen on buchungen;
create policy buchungen_lesen on buchungen for select to authenticated using (kunde = auth.uid() or ist_team());
drop policy if exists bewegungen_lesen on bewegungen;
create policy bewegungen_lesen on bewegungen for select to authenticated using (kunde = auth.uid() or ist_team());
drop policy if exists protokoll_lesen on protokoll;
create policy protokoll_lesen on protokoll for select to authenticated using (meine_rolle() = 'admin');
drop policy if exists anfragen_lesen on anfragen;
create policy anfragen_lesen on anfragen for select to authenticated using (kunde = auth.uid() or ist_team());

revoke all on all tables in schema public from anon, authenticated;
grant select on all tables in schema public to authenticated;
revoke execute on all functions in schema public from public, anon;
grant execute on function credits_buchen, max_stunden, stornieren, anfrage_eintragen, zahlung_bestaetigen,
  blockieren, credits_aufladen, korrektur, verfall_buchen, mitglieder_monatslauf, konto, kalender,
  partner_abrechnung, anfrage_senden, profil_setzen, meine_rolle, ist_team, mein_partner to authenticated;
-- interne Hilfsfunktionen nicht direkt aufrufbar
revoke execute on function posten_rest, nutzbare_posten, anfragen_verfallen_lassen, log_aktion, neuer_benutzer from authenticated;
