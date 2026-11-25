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
  ('s5','Studio 5 · BlackClouds Premium',4.5,'blackclouds',35,null,false,5),
  ('lounge','Lounge, Küche und Chill-Area',1,null,null,null,false,9)   -- nur Veranstaltungen, nie mit Credits
on conflict (id) do nothing;

create table if not exists profiles (
  id         uuid primary key references auth.users(id) on delete cascade,
  rolle      text not null default 'kunde' check (rolle in ('admin','team','partner','kunde')),
  partner    text check (partner in ('basement','blackclouds')),
  kn         text unique,                          -- KN-0xx (Kunden)
  name       text not null,
  telefon    text,
  aktiv      boolean not null default true,         -- false = gesperrt (kann sich nicht mehr anmelden/buchen)
  team_rolle text default 'buchung' check (team_rolle in ('buchung','geld','marketing','betrieb','records')),
  erstellt_am timestamptz not null default now(),
  check (rolle <> 'partner' or partner is not null)
);

-- Mitgliedschaften und Pauschalen (Monatsguthaben)
create table if not exists mitgliedschaften (
  id             bigserial primary key,
  kunde          uuid not null references profiles(id),
  tarif          text not null,                    -- z. B. 'PA 202 M', 'Basement 40'
  tarif_id       text,                             -- Verweis auf tarife(id), für Regeln wie die Partner-Obergrenze
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
  gruppe        bigint,                            -- Veranstaltung: Lounge + Studio 1 gemeinsam
  nicht_erschienen boolean not null default false,
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
    if not darf('eintragen') then raise exception 'KEIN_ZUGRIFF'; end if;
    if p_kunde is null then raise exception 'KUNDE_FEHLT'; end if;
    if not (select aktiv from profiles where id = p_kunde) then raise exception 'KONTO_GESPERRT'; end if;
    v_kunde := p_kunde;
  else
    raise exception 'KEIN_ZUGRIFF';
  end if;

  select * into v_st from studios where id = p_studio;
  if not found or not v_st.aktiv then raise exception 'STUDIO_INAKTIV'; end if;
  if p_studio = 'lounge' then raise exception 'NUR_VERANSTALTUNG'; end if;
  if v_rolle = 'kunde' and not v_st.selbst_buchbar
     and not exists (select 1 from freigaben f where f.kunde = v_kunde and f.studio = p_studio) then
    raise exception 'NUR_AUF_ANFRAGE';
  end if;
  if p_stunden < 2 then raise exception 'MINDESTENS_2_STUNDEN'; end if;
  if p_stunden > 24 or (p_stunden * 2) <> floor(p_stunden * 2) then raise exception 'UNGUELTIGE_DAUER'; end if;
  if p_start < now() then raise exception 'VERGANGENHEIT'; end if;

  -- Pro Kunde nacheinander buchen, damit dasselbe Guthaben nie doppelt verwendet wird
  perform pg_advisory_xact_lock(hashtext('konto:' || v_kunde::text));
  perform anfragen_verfallen_lassen();

  v_tag := berlin_datum(p_start + make_interval(mins => (p_stunden * 60)::int) - interval '1 second');
  -- Credits müssen am Ende des Termins noch gültig sein; Beginn-Tag muss im Gültigkeitszeitraum liegen
  v_bedarf := round(p_stunden * v_st.credits_pro_std, 2);
  perform partner_grenze_pruefen(v_kunde, p_studio, p_start, v_bedarf);

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
declare v_rolle text := meine_rolle(); b buchungen; v_erstatten boolean; v_mitglied boolean; v_frist interval; v_halb numeric;
begin
  if v_rolle is null then raise exception 'NICHT_ANGEMELDET'; end if;
  select * into b from buchungen where id = p_buchung for update;
  if not found then raise exception 'NICHT_GEFUNDEN'; end if;
  if v_rolle = 'kunde' and b.kunde is distinct from auth.uid() then raise exception 'KEIN_ZUGRIFF'; end if;
  if v_rolle = 'partner' and not (b.status = 'blockiert' and b.eigennutzung_partner = mein_partner()) then raise exception 'KEIN_ZUGRIFF'; end if;
  if b.status not in ('angefragt','gebucht','geschlossen','blockiert') then raise exception 'NICHT_STORNIERBAR'; end if;
  if lower(b.zeitraum) <= now() and v_rolle <> 'admin' then raise exception 'BEREITS_BEGONNEN'; end if;
  if p_kulanz and v_rolle <> 'admin' then raise exception 'KEIN_ZUGRIFF'; end if;
  if v_rolle = 'team' and not darf('eintragen') then raise exception 'KEIN_ZUGRIFF'; end if;
  if b.gruppe is not null then
    update buchungen set status = 'storniert', storniert_von = auth.uid(), storniert_am = now()
     where gruppe = b.gruppe and status = 'geschlossen';
    perform log_aktion('stornieren', jsonb_build_object('veranstaltung', b.gruppe));
    return 'STORNIERT';
  end if;

  -- Mitglieds-, Label- und Basement-Credits: Frist 12 Std., danach halbe Credits. Paket-Credits: 24 Std., danach alle weg.
  v_mitglied := exists (select 1 from zuordnungen z join credit_posten p on p.id = z.posten
                         where z.buchung = b.id and p.art in ('mitglied','label','basement'));
  v_frist := case when v_mitglied then interval '12 hours' else interval '24 hours' end;
  v_erstatten := b.credits > 0 and (lower(b.zeitraum) - now() > v_frist or p_kulanz);

  if b.credits > 0 and not v_erstatten and v_mitglied then
    -- Hälfte zurück: Zuordnungen und Buchung auf die angerechnete Hälfte kürzen
    v_halb := round(b.credits / 2, 2);
    update zuordnungen set credits = round(credits / 2, 2) where buchung = b.id;
    update buchungen set status = 'storniert', storniert_von = auth.uid(), storniert_am = now(),
                         erstattet = false, credits = v_halb
     where id = p_buchung;
    insert into bewegungen(kunde, art, credits, buchung, von, notiz)
    values (b.kunde, 'storno', b.credits - v_halb, b.id, auth.uid(), 'Spätes Storno Mitglied: halbe Credits angerechnet');
    perform log_aktion('stornieren', jsonb_build_object('buchung', p_buchung, 'halb', true));
    return 'HALB_ERSTATTET';
  end if;

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
  if not darf('eintragen') then raise exception 'KEIN_ZUGRIFF'; end if;
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
  if not darf('aufladen') then raise exception 'KEIN_ZUGRIFF'; end if;
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
    if not darf('eintragen') then raise exception 'KEIN_ZUGRIFF'; end if;
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
  if not darf('aufladen') then raise exception 'KEIN_ZUGRIFF'; end if;
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
           when v_rolle = 'partner' and v_partner = 'basement' and exists (select 1 from mitgliedschaften m
                where m.kunde = b.kunde and m.basement_pauschale) then pr.name || ' · Ihre Pauschale'
           when b.status = 'geschlossen' then 'Veranstaltung'
           else 'Belegt'
         end,
         b.kunde = auth.uid(),
         case when v_rolle in ('admin','team') or b.kunde = auth.uid() then b.status else 'belegt' end
    from buchungen b
    left join profiles pr on pr.id = b.kunde
    join studios s on s.id = b.studio
   where b.status in ('angefragt','gebucht','geschlossen','blockiert')
     and b.zeitraum && tstzrange(p_von, p_bis, '[)')
     and (v_rolle <> 'partner' or s.partner = v_partner or s.id in ('s1','lounge'))
     and (b.status <> 'angefragt' or b.reserviert_bis >= now())
   order by lower(b.zeitraum);
end $$;

-- Partner-Abrechnung je Monat. BlackClouds: Credits 14 / 35 € je Stunde, Walk-In 70 % vom Bruttopreis.
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
  -- BlackClouds, Credits: Festbetrag je angerechneter Stunde (= angerechnete Credits / Credits pro Stunde).
  -- Späte Stornos zählen so weit, wie dem Kunden Credits angerechnet wurden (Mitglieder: halb).
  select s.partner, s.name || ' · Credit-Stunden', round(sum(b.credits / s.credits_pro_std), 2),
         round(sum(b.credits / s.credits_pro_std) * s.partner_eur_std, 2)
    from buchungen b join studios s on s.id = b.studio
   where s.partner_eur_std is not null and b.status in ('gebucht','storniert') and not b.erstattet
     and b.credits > 0
     and berlin_datum(lower(b.zeitraum)) between v_von and v_bis
     and (v_partner is null or s.partner = v_partner)
   group by s.partner, s.name, s.partner_eur_std, s.credits_pro_std
  union all
  -- BlackClouds, Walk-In: 70 % des vom Kunden gezahlten Bruttopreises
  select s.partner, s.name || ' · Walk-In (70 % brutto)', count(*)::numeric, round(sum(b.preis_brutto) * 0.7, 2)
    from buchungen b join studios s on s.id = b.studio
   where s.partner = 'blackclouds' and b.status = 'gebucht' and b.credits = 0 and b.preis_brutto is not null
     and berlin_datum(lower(b.zeitraum)) between v_von and v_bis
     and (v_partner is null or s.partner = v_partner)
   group by s.partner, s.name
  union all
  -- Basement: CloudStudios-Credits in Studio 3 (ohne Basement- und Bonus-Credits)
  select 'basement', 'Studio 3 · CloudStudios-Credits', coalesce(sum(z.credits),0), coalesce(sum(z.credits),0) * 5
    from zuordnungen z join buchungen b on b.id = z.buchung join credit_posten p on p.id = z.posten
   where b.studio = 's3' and not b.erstattet and p.art not in ('basement','bonus')
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
  p_rolle text default null, p_partner text default null, p_aktiv boolean default null, p_team_rolle text default null) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not ist_team() then raise exception 'KEIN_ZUGRIFF'; end if;
  if (p_rolle is not null or p_partner is not null or p_team_rolle is not null) and meine_rolle() <> 'admin' then raise exception 'KEIN_ZUGRIFF'; end if;
  if p_aktiv is not null and not darf('konten') then raise exception 'KEIN_ZUGRIFF'; end if;   -- Sperren/Entsperren
  update profiles set name = coalesce(p_name, name), kn = coalesce(p_kn, kn),
                      rolle = coalesce(p_rolle, rolle), partner = coalesce(p_partner, partner),
                      aktiv = coalesce(p_aktiv, aktiv), team_rolle = coalesce(p_team_rolle, team_rolle)
   where id = p_id;
  if not found then raise exception 'NICHT_GEFUNDEN'; end if;
  perform log_aktion('profil_setzen', jsonb_build_object('profil', p_id, 'rolle', p_rolle, 'partner', p_partner, 'aktiv', p_aktiv, 'team_rolle', p_team_rolle));
end $$;

-- =====================================================================
-- Erweiterungen 24.11.2026: Tarife, Rechte, Studio-5-Bewerbung und
-- Freigabeliste, Partner-Obergrenze, Veranstaltungen, nicht erschienen,
-- Zustandsmeldungen, Mitteilungen, Gutschrift-Bestätigung.
-- Puffer (Variante A): Wechselzeit ist in der Stunde enthalten, Kunden
-- räumen bis :45. Die App zeigt das an; die Datenbank bucht volle Stunden.
-- =====================================================================

-- Tarife und Pauschalen: legt der Admin in der App an (auch neue Basement-Pauschalen)
create table if not exists tarife (
  id                text primary key,                 -- 'PA 201', 'Basement 40', 'Label 20'
  name              text not null,
  art               text not null check (art in ('mitglied','basement','label')),
  credits_monat     numeric(6,2) not null check (credits_monat > 0),
  beitrag_brutto    numeric(8,2) not null default 0,
  nur_studios       text[],                           -- null = alle selbst buchbaren
  partner_max_monat numeric(6,2),                     -- höchstens so viele Credits pro Monat in Partnerstudios
  nur_einladung     boolean not null default false,
  aktiv             boolean not null default true
);
insert into tarife (id,name,art,credits_monat,beitrag_brutto,nur_studios,partner_max_monat,nur_einladung) values
  ('PA 201','Multi-Studio S','mitglied',20,267.75,null,null,false),
  ('PA 202','Multi-Studio M','mitglied',30,392.70,null,null,false),
  ('PA 203','Multi-Studio L','mitglied',40,476.00,null,null,false),
  ('PA 204','Multi-Studio XL','mitglied',50,535.50,null,null,false),
  ('PA 210','Family & Friends','mitglied',24,178.50,array['s1'],null,true),
  ('PA 220','CloudsMember','mitglied',60,654.50,null,30,true),
  ('PA 230','Basement-Pauschale','basement',40,300,array['s3'],null,false),
  ('Label 20','Clouds Records','label',20,0,array['s1'],null,false)
on conflict (id) do nothing;
-- Beiträge brutto laut Preisliste 2027; Änderungen in der App unter Tarife.

-- Einstellungen (Schlüssel → Wert), z. B. Kriterien der Studio-5-Prüfliste
create table if not exists einstellungen (
  schluessel text primary key,
  wert       jsonb not null,
  geaendert_von uuid,
  geaendert_am  timestamptz not null default now()
);
insert into einstellungen(schluessel, wert) values
  ('s5_min_hoerer', '2'),      -- Stufe: 0 <1.000 · 1 1.000–10.000 · 2 10.000–50.000 · 3 50.000–250.000 · 4 >250.000
  ('s5_min_releases', '1'),    -- Stufe: 0 keine · 1 1–2 · 2 3–5 · 3 6+
  ('s5_ohne_noshow', 'true')
on conflict (schluessel) do nothing;

-- Rechte je Team-Rolle. Admin darf immer alles. Schalter setzt nur der Admin.
create table if not exists rollen_rechte (
  rolle text not null check (rolle in ('buchung','geld','marketing','betrieb','records')),
  recht text not null check (recht in ('kalender','eintragen','anfragen','kunden','codes','aufladen','kulanz',
                                       'zahlen','abrechnung','konten','einstellungen')),
  primary key (rolle, recht)
);
insert into rollen_rechte(rolle, recht) values
  ('buchung','kalender'),('buchung','eintragen'),('buchung','anfragen'),('buchung','kunden'),('buchung','codes'),
  ('geld','kalender'),('geld','zahlen'),('geld','abrechnung'),
  ('marketing','zahlen'),
  ('betrieb','kalender'),('betrieb','codes'),('betrieb','anfragen'),
  ('records','kalender'),('records','kunden')
on conflict do nothing;
-- 'aufladen' (Credits aufladen, Zahlung bestätigen) ist bewusst noch bei niemandem an.

create or replace function darf(p_recht text) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select case when pr.rolle = 'admin' then true
                               when pr.rolle = 'team' then exists (select 1 from rollen_rechte r
                                                                    where r.rolle = coalesce(pr.team_rolle, 'buchung') and r.recht = p_recht)
                               else false end
                     from profiles pr where pr.id = auth.uid() and pr.aktiv), false)
$$;

create or replace function recht_setzen(p_rolle text, p_recht text, p_an boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  if meine_rolle() <> 'admin' then raise exception 'KEIN_ZUGRIFF'; end if;
  if p_an then insert into rollen_rechte values (p_rolle, p_recht) on conflict do nothing;
  else delete from rollen_rechte where rolle = p_rolle and recht = p_recht; end if;
  perform log_aktion('recht_setzen', jsonb_build_object('rolle', p_rolle, 'recht', p_recht, 'an', p_an));
end $$;

create or replace function tarif_speichern(p_id text, p_name text, p_art text, p_credits numeric, p_brutto numeric,
  p_nur text[] default null, p_partner_max numeric default null, p_einladung boolean default false, p_aktiv boolean default true)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if not darf('einstellungen') then raise exception 'KEIN_ZUGRIFF'; end if;
  insert into tarife values (p_id, p_name, p_art, p_credits, p_brutto, p_nur, p_partner_max, p_einladung, p_aktiv)
  on conflict (id) do update set name = excluded.name, art = excluded.art, credits_monat = excluded.credits_monat,
    beitrag_brutto = excluded.beitrag_brutto, nur_studios = excluded.nur_studios, partner_max_monat = excluded.partner_max_monat,
    nur_einladung = excluded.nur_einladung, aktiv = excluded.aktiv;
  perform log_aktion('tarif_speichern', jsonb_build_object('tarif', p_id, 'credits', p_credits, 'brutto', p_brutto, 'partner_max', p_partner_max));
end $$;

create or replace function einstellung_setzen(p_schluessel text, p_wert jsonb) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not darf('einstellungen') then raise exception 'KEIN_ZUGRIFF'; end if;
  insert into einstellungen(schluessel, wert, geaendert_von) values (p_schluessel, p_wert, auth.uid())
  on conflict (schluessel) do update set wert = excluded.wert, geaendert_von = excluded.geaendert_von, geaendert_am = now();
  perform log_aktion('einstellung_setzen', jsonb_build_object('schluessel', p_schluessel, 'wert', p_wert));
end $$;

-- Mitgliedschaft oder Pauschale aus einem Tarif anlegen (Credits kommen über den Monatslauf)
create or replace function mitgliedschaft_anlegen(p_kunde uuid, p_tarif text, p_ab date, p_vn text default null)
returns bigint
language plpgsql security definer set search_path = public as $$
declare t tarife; v_id bigint;
begin
  if not darf('konten') then raise exception 'KEIN_ZUGRIFF'; end if;
  select * into t from tarife where id = p_tarif and aktiv;
  if not found then raise exception 'TARIF_UNBEKANNT'; end if;
  insert into mitgliedschaften(kunde, tarif, tarif_id, credits_monat, nur_studios, beitrag_brutto, basement_pauschale, aktiv_ab, vn)
  values (p_kunde, trim(t.id || ' ' || case when t.name <> t.id then t.name else '' end), t.id, t.credits_monat, t.nur_studios,
          t.beitrag_brutto, t.art = 'basement', p_ab, p_vn)
  returning id into v_id;
  perform log_aktion('mitgliedschaft_anlegen', jsonb_build_object('mitgliedschaft', v_id, 'kunde', p_kunde, 'tarif', p_tarif));
  return v_id;
end $$;

-- Obergrenze für Partnerstudios (z. B. PA 220: 30 Credits pro Monat). Wird in credits_buchen aufgerufen.
create or replace function partner_grenze_pruefen(p_kunde uuid, p_studio text, p_start timestamptz, p_bedarf numeric)
returns void
language plpgsql stable security definer set search_path = public as $$
declare v_max numeric; v_genutzt numeric; v_monat date := date_trunc('month', berlin_datum(p_start))::date;
begin
  if (select partner from studios where id = p_studio) is null then return; end if;
  select min(t.partner_max_monat) into v_max
    from mitgliedschaften m join tarife t on t.id = m.tarif_id
   where m.kunde = p_kunde and t.partner_max_monat is not null
     and m.aktiv_ab <= monatsende(v_monat) and (m.aktiv_bis is null or m.aktiv_bis >= v_monat);
  if v_max is null then return; end if;
  select coalesce(sum(b.credits), 0) into v_genutzt
    from buchungen b join studios s on s.id = b.studio
   where b.kunde = p_kunde and s.partner is not null and not b.erstattet
     and b.status in ('gebucht','storniert')
     and date_trunc('month', berlin_datum(lower(b.zeitraum)))::date = v_monat;
  if v_genutzt + p_bedarf > v_max then
    raise exception 'PARTNER_GRENZE:%', trim_scale(greatest(v_max - v_genutzt, 0));
  end if;
end $$;

-- Veranstaltung: sperrt Lounge und Studio 1 gemeinsam (rot). Beides frei oder gar nichts.
create or replace function veranstaltung_eintragen(p_start timestamptz, p_ende timestamptz, p_titel text)
returns bigint
language plpgsql security definer set search_path = public as $$
declare v_gruppe bigint;
begin
  if not darf('eintragen') then raise exception 'KEIN_ZUGRIFF'; end if;
  perform anfragen_verfallen_lassen();
  v_gruppe := nextval(pg_get_serial_sequence('buchungen', 'id'));
  begin
    insert into buchungen(studio, zeitraum, status, grund, gruppe, erstellt_von)
    values ('lounge', tstzrange(p_start, p_ende, '[)'), 'geschlossen', p_titel, v_gruppe, auth.uid()),
           ('s1', tstzrange(p_start, p_ende, '[)'), 'geschlossen', p_titel || ' (gesperrt)', v_gruppe, auth.uid());
  exception when exclusion_violation then raise exception 'SLOT_BELEGT';
  end;
  perform log_aktion('veranstaltung_eintragen', jsonb_build_object('gruppe', v_gruppe, 'start', p_start, 'titel', p_titel));
  return v_gruppe;
end $$;

-- Studio 5: dauerhafte Freigabe (BlackClouds oder Admin)
create table if not exists freigaben (
  kunde  uuid not null references profiles(id),
  studio text not null references studios(id),
  von    uuid references profiles(id),
  am     timestamptz not null default now(),
  primary key (kunde, studio)
);

create or replace function freigabe_setzen(p_kunde uuid, p_an boolean, p_studio text default 's5') returns void
language plpgsql security definer set search_path = public as $$
begin
  if not (meine_rolle() = 'admin' or mein_partner() = (select partner from studios where id = p_studio)) then
    raise exception 'KEIN_ZUGRIFF';
  end if;
  if p_an then insert into freigaben(kunde, studio, von) values (p_kunde, p_studio, auth.uid()) on conflict do nothing;
  else delete from freigaben where kunde = p_kunde and studio = p_studio; end if;
  perform log_aktion('freigabe_setzen', jsonb_build_object('kunde', p_kunde, 'studio', p_studio, 'an', p_an));
end $$;

-- Studio 5: Bewerbung des Kunden, Entscheidung durch BlackClouds
create table if not exists bewerbungen (
  id          bigserial primary key,
  kunde       uuid not null references profiles(id),
  studio      text not null default 's5' references studios(id),
  wunsch_start timestamptz not null,
  stunden     numeric(4,1) not null check (stunden >= 2),
  kuenstler   text not null,
  link        text not null,
  hoerer_stufe   int not null check (hoerer_stufe between 0 and 4),
  releases_stufe int not null check (releases_stufe between 0 and 3),
  label       text,
  projekt     text not null,
  engineer    boolean not null default false,
  regeln      boolean not null check (regeln),       -- ohne Zustimmung keine Bewerbung
  status      text not null default 'offen' check (status in ('offen','zugesagt','abgelehnt','eingetragen')),
  dauerhaft   boolean not null default false,
  entschieden_von uuid references profiles(id),
  entschieden_am  timestamptz,
  buchung     bigint references buchungen(id),
  erstellt_am timestamptz not null default now()
);

create or replace function bewerbung_senden(p_start timestamptz, p_stunden numeric, p_kuenstler text, p_link text,
  p_hoerer int, p_releases int, p_label text, p_projekt text, p_engineer boolean, p_regeln boolean)
returns bigint
language plpgsql security definer set search_path = public as $$
declare v_id bigint;
begin
  if meine_rolle() <> 'kunde' then raise exception 'KEIN_ZUGRIFF'; end if;
  if not coalesce(p_regeln, false) then raise exception 'REGELN_NICHT_AKZEPTIERT'; end if;
  if p_start < now() then raise exception 'VERGANGENHEIT'; end if;
  insert into bewerbungen(kunde, wunsch_start, stunden, kuenstler, link, hoerer_stufe, releases_stufe, label, projekt, engineer, regeln)
  values (auth.uid(), p_start, p_stunden, p_kuenstler, p_link, p_hoerer, p_releases, nullif(trim(p_label), ''), p_projekt, p_engineer, p_regeln)
  returning id into v_id;
  perform log_aktion('bewerbung_senden', jsonb_build_object('bewerbung', v_id));
  return v_id;
end $$;

create or replace function bewerbung_pruefliste(p_id bigint)
returns table(kriterium text, erfuellt boolean)
language plpgsql stable security definer set search_path = public as $$
declare b bewerbungen; v_h int; v_r int; v_ns boolean;
begin
  select * into b from bewerbungen where id = p_id;
  if not found then raise exception 'NICHT_GEFUNDEN'; end if;
  if not (ist_team() or mein_partner() = 'blackclouds' or b.kunde = auth.uid()) then raise exception 'KEIN_ZUGRIFF'; end if;
  select (wert #>> '{}')::int into v_h from einstellungen where schluessel = 's5_min_hoerer';
  select (wert #>> '{}')::int into v_r from einstellungen where schluessel = 's5_min_releases';
  select (wert #>> '{}')::boolean into v_ns from einstellungen where schluessel = 's5_ohne_noshow';
  return query values
    ('Reichweite', b.hoerer_stufe >= coalesce(v_h, 2)),
    ('Releases in 12 Monaten', b.releases_stufe >= coalesce(v_r, 1)),
    ('Professionelles Umfeld (Label, Management, Team)', b.label is not null),
    ('Regeln akzeptiert', b.regeln);
  if coalesce(v_ns, true) then
    return query select 'Keine nicht wahrgenommenen Termine'::text,
      not exists (select 1 from buchungen x where x.kunde = b.kunde and x.nicht_erschienen);
  end if;
end $$;

create or replace function bewerbung_entscheiden(p_id bigint, p_zusage boolean, p_dauerhaft boolean default false)
returns void
language plpgsql security definer set search_path = public as $$
declare b bewerbungen;
begin
  if not (meine_rolle() = 'admin' or mein_partner() = 'blackclouds') then raise exception 'KEIN_ZUGRIFF'; end if;
  select * into b from bewerbungen where id = p_id for update;
  if not found then raise exception 'NICHT_GEFUNDEN'; end if;
  if b.status <> 'offen' then raise exception 'SCHON_ENTSCHIEDEN'; end if;
  update bewerbungen set status = case when p_zusage then 'zugesagt' else 'abgelehnt' end,
         dauerhaft = p_zusage and p_dauerhaft, entschieden_von = auth.uid(), entschieden_am = now()
   where id = p_id;
  if p_zusage and p_dauerhaft then
    insert into freigaben(kunde, studio, von) values (b.kunde, b.studio, auth.uid()) on conflict do nothing;
  end if;
  perform log_aktion('bewerbung_entscheiden', jsonb_build_object('bewerbung', p_id, 'zusage', p_zusage, 'dauerhaft', p_dauerhaft));
end $$;
-- Nach Zusage trägt das Team den Termin mit credits_buchen(..., p_kunde) ein und setzt
-- bewerbungen.buchung über die App (status 'eingetragen').

-- Nicht erschienen (Team): zählt für die Studio-5-Prüfliste
create or replace function nicht_erschienen_setzen(p_buchung bigint, p_wert boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not darf('eintragen') then raise exception 'KEIN_ZUGRIFF'; end if;
  update buchungen set nicht_erschienen = p_wert where id = p_buchung and status = 'gebucht';
  if not found then raise exception 'NICHT_GEFUNDEN'; end if;
  perform log_aktion('nicht_erschienen', jsonb_build_object('buchung', p_buchung, 'wert', p_wert));
end $$;

-- Letzte Buchung in einem Raum vor jetzt (für Zustandsmeldungen). 'gemein' = Lounge/Küche + Studio 1.
create or replace function letzte_buchung_vor(p_raum text, p_zeit timestamptz default now()) returns bigint
language sql stable security definer set search_path = public as $$
  select b.id from buchungen b
   where b.studio = any(case when p_raum = 'gemein' then array['lounge','s1'] else array[p_raum] end)
     and b.status in ('gebucht','geschlossen') and b.eigennutzung_partner is null
     and lower(b.zeitraum) <= p_zeit
   order by upper(b.zeitraum) desc limit 1
$$;

create table if not exists zustandsmeldungen (
  id         bigserial primary key,
  partner    text check (partner in ('basement','blackclouds')),   -- null = vom Team
  raum       text not null,                                         -- s1, s3, s4, s5, gemein
  text       text not null,
  foto_pfad  text,                                                  -- Supabase Storage
  buchung    bigint references buchungen(id),                       -- automatisch: letzte Buchung im Raum
  status     text not null default 'offen' check (status in ('offen','erledigt')),
  von        uuid references profiles(id),
  am         timestamptz not null default now()
);

create or replace function zustand_melden(p_raum text, p_text text, p_foto text default null) returns bigint
language plpgsql security definer set search_path = public as $$
declare v_partner text := mein_partner(); v_id bigint;
begin
  if not (ist_team() or v_partner is not null) then raise exception 'KEIN_ZUGRIFF'; end if;
  if v_partner is not null and p_raum <> 'gemein'
     and (select partner from studios where id = p_raum) is distinct from v_partner then raise exception 'KEIN_ZUGRIFF'; end if;
  if p_text is null or length(trim(p_text)) < 3 then raise exception 'TEXT_FEHLT'; end if;
  insert into zustandsmeldungen(partner, raum, text, foto_pfad, buchung, von)
  values (v_partner, p_raum, p_text, p_foto, letzte_buchung_vor(p_raum), auth.uid())
  returning id into v_id;
  perform log_aktion('zustand_melden', jsonb_build_object('meldung', v_id, 'raum', p_raum));
  return v_id;
end $$;

create or replace function zustand_erledigt(p_id bigint) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not darf('anfragen') then raise exception 'KEIN_ZUGRIFF'; end if;
  update zustandsmeldungen set status = 'erledigt' where id = p_id;
  perform log_aktion('zustand_erledigt', jsonb_build_object('meldung', p_id));
end $$;

-- Mitteilungen zwischen CloudStudios und einem Partner
create table if not exists mitteilungen (
  id       bigserial primary key,
  partner  text not null check (partner in ('basement','blackclouds')),
  vom_partner boolean not null,
  text     text not null,
  von      uuid references profiles(id),
  am       timestamptz not null default now(),
  gelesen  boolean not null default false
);

create or replace function mitteilung_senden(p_partner text, p_text text) returns bigint
language plpgsql security definer set search_path = public as $$
declare v_partner text := mein_partner(); v_id bigint;
begin
  if v_partner is not null and v_partner <> p_partner then raise exception 'KEIN_ZUGRIFF'; end if;
  if v_partner is null and not ist_team() then raise exception 'KEIN_ZUGRIFF'; end if;
  if p_text is null or length(trim(p_text)) = 0 then raise exception 'TEXT_FEHLT'; end if;
  insert into mitteilungen(partner, vom_partner, text, von) values (p_partner, v_partner is not null, p_text, auth.uid())
  returning id into v_id;
  perform log_aktion('mitteilung_senden', jsonb_build_object('mitteilung', v_id, 'partner', p_partner));
  return v_id;
end $$;

-- Partner bestätigt die Gutschrift eines Monats
create table if not exists gutschrift_bestaetigungen (
  partner text not null check (partner in ('basement','blackclouds')),
  monat   date not null,
  von     uuid references profiles(id),
  am      timestamptz not null default now(),
  primary key (partner, monat)
);

create or replace function gutschrift_bestaetigen(p_monat date) returns void
language plpgsql security definer set search_path = public as $$
declare v_partner text := mein_partner();
begin
  if v_partner is null then raise exception 'KEIN_ZUGRIFF'; end if;
  insert into gutschrift_bestaetigungen(partner, monat, von)
  values (v_partner, date_trunc('month', p_monat)::date, auth.uid()) on conflict do nothing;
  perform log_aktion('gutschrift_bestaetigen', jsonb_build_object('partner', v_partner, 'monat', p_monat));
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

alter table tarife enable row level security;
alter table einstellungen enable row level security;
alter table rollen_rechte enable row level security;
alter table freigaben enable row level security;
alter table bewerbungen enable row level security;
alter table zustandsmeldungen enable row level security;
alter table mitteilungen enable row level security;
alter table gutschrift_bestaetigungen enable row level security;
drop policy if exists tarife_lesen on tarife;
create policy tarife_lesen on tarife for select to authenticated using (true);
drop policy if exists einstellungen_lesen on einstellungen;
create policy einstellungen_lesen on einstellungen for select to authenticated using (true);
drop policy if exists rechte_lesen on rollen_rechte;
create policy rechte_lesen on rollen_rechte for select to authenticated using (ist_team());
drop policy if exists freigaben_lesen on freigaben;
create policy freigaben_lesen on freigaben for select to authenticated using (kunde = auth.uid() or ist_team() or mein_partner() = 'blackclouds');
drop policy if exists bewerbungen_lesen on bewerbungen;
create policy bewerbungen_lesen on bewerbungen for select to authenticated using (kunde = auth.uid() or ist_team() or mein_partner() = 'blackclouds');
drop policy if exists zustand_lesen on zustandsmeldungen;
create policy zustand_lesen on zustandsmeldungen for select to authenticated using (ist_team() or partner = mein_partner());
drop policy if exists mitteilungen_lesen on mitteilungen;
create policy mitteilungen_lesen on mitteilungen for select to authenticated using (ist_team() or partner = mein_partner());
drop policy if exists gutschrift_lesen on gutschrift_bestaetigungen;
create policy gutschrift_lesen on gutschrift_bestaetigungen for select to authenticated using (meine_rolle() = 'admin' or partner = mein_partner());

revoke all on all tables in schema public from anon, authenticated;
grant select on all tables in schema public to authenticated;
revoke execute on all functions in schema public from public, anon;
grant execute on function credits_buchen, max_stunden, stornieren, anfrage_eintragen, zahlung_bestaetigen,
  blockieren, credits_aufladen, korrektur, verfall_buchen, mitglieder_monatslauf, konto, kalender,
  partner_abrechnung, anfrage_senden, profil_setzen, meine_rolle, ist_team, mein_partner,
  darf, recht_setzen, tarif_speichern, einstellung_setzen, mitgliedschaft_anlegen, veranstaltung_eintragen,
  freigabe_setzen, bewerbung_senden, bewerbung_entscheiden, bewerbung_pruefliste, nicht_erschienen_setzen,
  zustand_melden, zustand_erledigt, mitteilung_senden, gutschrift_bestaetigen, letzte_buchung_vor to authenticated;
-- interne Hilfsfunktionen nicht direkt aufrufbar
revoke execute on function posten_rest, nutzbare_posten, anfragen_verfallen_lassen, log_aktion, neuer_benutzer, partner_grenze_pruefen from authenticated;
