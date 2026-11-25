-- ============================================================
-- CloudStudios · Push-Mitteilungen
-- Jeder Nutzer schaltet Push selbst ein (pro Gerät) und wählt
-- die Mitteilungsarten. Ereignisse landen in einer Warteschlange,
-- die Edge Function „push_senden“ verschickt sie.
-- ============================================================

do $$ begin create extension if not exists pg_net; exception when others then raise notice 'pg_net nicht verfügbar'; end $$;

-- Geräte (ein Eintrag je Browser/Handy)
create table if not exists push_abos (
  id          bigserial primary key,
  nutzer      uuid not null references profiles(id) on delete cascade,
  endpoint    text not null unique,
  p256dh      text not null,
  auth        text not null,
  geraet      text,
  erstellt_am timestamptz not null default now()
);

-- Abgewählte Mitteilungsarten (leer = alle an)
create table if not exists push_einstellungen (
  nutzer uuid primary key references profiles(id) on delete cascade,
  aus    text[] not null default '{}'
);

-- Warteschlange
create table if not exists push_warteschlange (
  id          bigserial primary key,
  nutzer      uuid not null references profiles(id) on delete cascade,
  art         text not null,
  titel       text not null,
  text        text not null,
  url         text,
  ref         text,                     -- verhindert Doppelte (z. B. Buchung + Art)
  erstellt_am timestamptz not null default now(),
  gesendet_am timestamptz,
  ergebnis    text
);
create unique index if not exists push_warteschlange_ref on push_warteschlange(nutzer, art, ref) where ref is not null;
create index if not exists push_warteschlange_offen on push_warteschlange(erstellt_am) where gesendet_am is null;

alter table push_abos enable row level security;
alter table push_einstellungen enable row level security;
alter table push_warteschlange enable row level security;
-- Kein direkter Zugriff für Nutzer: nur über die Funktionen unten bzw. den Service-Schlüssel.

-- Versand anstoßen (sofort). Schlägt das fehl, holt der Zeitplan es nach.
create or replace function push_anstossen() returns void
language plpgsql security definer set search_path = public as $$
declare v_url text; v_key text;
begin
  select wert #>> '{}' into v_url from einstellungen where schluessel = 'push_funktion_url';
  select wert #>> '{}' into v_key from einstellungen where schluessel = 'push_funktion_key';
  if v_url is null then return; end if;
  begin
    perform net.http_post(url := v_url, body := '{}'::jsonb,
      headers := jsonb_build_object('Content-Type', 'application/json', 'apikey', coalesce(v_key, '')));
  exception when others then null;
  end;
end $$;

-- Eine Mitteilung für einen Nutzer einreihen (nur wenn er Push hat und die Art nicht abgewählt ist)
create or replace function push_an(p_nutzer uuid, p_art text, p_titel text, p_text text, p_url text default null, p_ref text default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  if p_nutzer is null then return; end if;
  if not exists (select 1 from push_abos where nutzer = p_nutzer) then return; end if;
  if exists (select 1 from push_einstellungen e where e.nutzer = p_nutzer and p_art = any(e.aus)) then return; end if;
  if not exists (select 1 from profiles where id = p_nutzer and aktiv) then return; end if;
  insert into push_warteschlange(nutzer, art, titel, text, url, ref)
  values (p_nutzer, p_art, p_titel, p_text, p_url, p_ref)
  on conflict do nothing;
end $$;

-- An alle mit Rolle (admin/team) bzw. an alle Zugänge eines Partners
create or replace function push_an_team(p_art text, p_titel text, p_text text, p_ref text default null, p_ausser uuid default null)
returns void language plpgsql security definer set search_path = public as $$
declare r record;
begin
  for r in select id from profiles where rolle in ('admin','team') and aktiv and id is distinct from p_ausser loop
    perform push_an(r.id, p_art, p_titel, p_text, null, p_ref);
  end loop;
end $$;

create or replace function push_an_partner(p_partner text, p_art text, p_titel text, p_text text, p_ref text default null, p_ausser uuid default null)
returns void language plpgsql security definer set search_path = public as $$
declare r record;
begin
  if p_partner is null then return; end if;
  for r in select id from profiles where rolle = 'partner' and partner = p_partner and aktiv and id is distinct from p_ausser loop
    perform push_an(r.id, p_art, p_titel, p_text, null, p_ref);
  end loop;
end $$;

-- Kurzform für Zeitpunkte: „Mi 26.11., 14:00“
create or replace function push_zeit(p timestamptz) returns text language sql immutable as $$
  select (array['So','Mo','Di','Mi','Do','Fr','Sa'])[extract(dow from p at time zone 'Europe/Berlin')::int + 1]
         || ' ' || to_char(p at time zone 'Europe/Berlin', 'DD.MM., HH24:MI') || ' Uhr'
$$;

-- ---------- Auslöser ----------

-- Buchungen
create or replace function push_buchung() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_studio text; v_partner text; v_wann text; v_wer text;
begin
  select name, partner into v_studio, v_partner from studios where id = new.studio;
  v_wann := push_zeit(lower(new.zeitraum));
  select coalesce(p.name, new.gast_name, 'Kunde') into v_wer from profiles p where p.id = new.kunde;
  v_wer := coalesce(v_wer, new.gast_name, 'Walk-In');

  if tg_op = 'INSERT' then
    if new.status = 'angefragt' then
      perform push_an_team('anfrage', 'Neue Anfrage', v_studio || ' · ' || v_wann || ' · ' || v_wer, 'b' || new.id, new.erstellt_von);
    elsif new.status = 'blockiert' and new.eigennutzung_partner is not null then
      perform push_an_team('buchung', 'Eigennutzung eingetragen', v_studio || ' · ' || v_wann || coalesce(' · ' || (select name from profiles where id = new.erstellt_von), ''), 'b' || new.id, new.erstellt_von);
      perform push_an_partner(new.eigennutzung_partner, 'p_buchung', 'Eigennutzung eingetragen', v_studio || ' · ' || v_wann || coalesce(' · ' || (select name from profiles where id = new.erstellt_von), ''), 'b' || new.id, new.erstellt_von);
    elsif new.status = 'gebucht' then
      perform push_an_team('buchung', 'Neue Buchung', v_studio || ' · ' || v_wann || ' · ' || v_wer, 'b' || new.id, new.erstellt_von);
      if new.eigennutzung_partner is null then
        perform push_an_partner(v_partner, 'p_buchung', 'Neue Buchung in Ihrem Studio', v_studio || ' · ' || v_wann, 'b' || new.id, new.erstellt_von);
      end if;
      if new.kunde is not null and new.kunde is distinct from new.erstellt_von then
        perform push_an(new.kunde, 'bestaetigt', 'Buchung bestätigt', v_studio || ' · ' || v_wann, null, 'b' || new.id);
      end if;
    end if;
    return new;
  end if;

  if new.status is distinct from old.status then
    if old.status = 'angefragt' and new.status = 'gebucht' then
      perform push_an(new.kunde, 'bestaetigt', 'Buchung bestätigt', v_studio || ' · ' || v_wann, null, 'b' || new.id);
      perform push_an_partner(v_partner, 'p_buchung', 'Neue Buchung in Ihrem Studio', v_studio || ' · ' || v_wann, 'b' || new.id);
    elsif new.status = 'storniert' and old.status in ('angefragt','gebucht') then
      if new.kunde is distinct from new.storniert_von then
        perform push_an(new.kunde, 'storno', 'Buchung storniert', v_studio || ' · ' || v_wann, null, 'bs' || new.id);
      end if;
      if old.status = 'gebucht' and new.eigennutzung_partner is null then
        perform push_an_partner(v_partner, 'p_storno', 'Buchung storniert', v_studio || ' · ' || v_wann, 'bs' || new.id, new.storniert_von);
      end if;
      perform push_an_team('buchung', 'Buchung storniert', v_studio || ' · ' || v_wann || ' · ' || v_wer, 'bs' || new.id, new.storniert_von);
    elsif new.status = 'verfallen' then
      perform push_an(new.kunde, 'storno', 'Reservierung abgelaufen', v_studio || ' · ' || v_wann || ' – die Zahlung ist nicht rechtzeitig eingegangen.', null, 'bv' || new.id);
    end if;
  end if;
  return new;
end $$;
drop trigger if exists push_buchung on buchungen;
create trigger push_buchung after insert or update of status on buchungen for each row execute function push_buchung();

-- Freie Anfragen (z. B. Veranstaltungen, Pakete)
create or replace function push_anfrage() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  perform push_an_team('anfrage', 'Neue Anfrage', left(coalesce((select name from profiles where id = new.kunde), 'Kunde') || ': ' || new.wunsch, 140), 'a' || new.id, new.kunde);
  return new;
end $$;
drop trigger if exists push_anfrage on anfragen;
create trigger push_anfrage after insert on anfragen for each row execute function push_anfrage();

-- Studio-5-Bewerbungen: Admin und BlackClouds
create or replace function push_bewerbung() returns trigger
language plpgsql security definer set search_path = public as $$
declare r record;
begin
  for r in select id from profiles where rolle = 'admin' and aktiv loop
    perform push_an(r.id, 'bewerbung', 'Neue Studio-5-Bewerbung', new.kuenstler || ' · ' || push_zeit(new.wunsch_start), null, 'w' || new.id);
  end loop;
  perform push_an_partner('blackclouds', 'bewerbung', 'Neue Studio-5-Bewerbung', new.kuenstler || ' · ' || push_zeit(new.wunsch_start), 'w' || new.id);
  return new;
end $$;
drop trigger if exists push_bewerbung on bewerbungen;
create trigger push_bewerbung after insert on bewerbungen for each row execute function push_bewerbung();

-- Mitteilungen zwischen CloudStudios und Partnern
create or replace function push_mitteilung() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.vom_partner then
    perform push_an_team('mitteilung', 'Mitteilung von ' || case new.partner when 'basement' then 'Basement' else 'BlackClouds' end, left(new.text, 140), 'm' || new.id, new.von);
  else
    perform push_an_partner(new.partner, 'mitteilung', 'Mitteilung von CloudStudios', left(new.text, 140), 'm' || new.id, new.von);
  end if;
  return new;
end $$;
drop trigger if exists push_mitteilung on mitteilungen;
create trigger push_mitteilung after insert on mitteilungen for each row execute function push_mitteilung();

-- Zustandsmeldungen (Schäden, Ordnung)
create or replace function push_zustand() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  perform push_an_team('zustand', 'Neue Zustandsmeldung', left(new.raum || ': ' || new.text, 140), 'z' || new.id, new.von);
  return new;
end $$;
drop trigger if exists push_zustand on zustandsmeldungen;
create trigger push_zustand after insert on zustandsmeldungen for each row execute function push_zustand();

-- Nach jedem Eintrag in der Warteschlange sofort verschicken lassen
create or replace function push_neu() returns trigger
language plpgsql security definer set search_path = public as $$
begin perform push_anstossen(); return null; end $$;
drop trigger if exists push_neu on push_warteschlange;
create trigger push_neu after insert on push_warteschlange for each statement execute function push_neu();

-- ---------- Zeitgesteuerte Mitteilungen ----------
create or replace function push_zeitplan() returns void
language plpgsql security definer set search_path = public as $$
declare r record; v_jetzt timestamptz := now(); v_heute date := (now() at time zone 'Europe/Berlin')::date; v_anzahl int;
begin
  -- 24 Stunden vorher: Buchung verbindlich, Türcode in der App
  for r in select b.id, b.kunde, b.zeitraum, s.name from buchungen b join studios s on s.id = b.studio
            where b.status = 'gebucht' and b.kunde is not null
              and lower(b.zeitraum) > v_jetzt + interval '22 hours' and lower(b.zeitraum) <= v_jetzt + interval '24 hours' loop
    perform push_an(r.kunde, 'verbindlich', 'Buchung ist verbindlich', r.name || ' · ' || push_zeit(lower(r.zeitraum)) || ' – Ihren Türcode finden Sie in der App.', null, 'v' || r.id);
  end loop;

  -- Einmal am Tag ab 10 Uhr
  if extract(hour from now() at time zone 'Europe/Berlin') >= 10 then
    -- Credits laufen in 7 Tagen ab
    for r in select p.id, p.kunde, p.gueltig_bis, posten_rest(p.id) as rest from credit_posten p
              where p.gueltig_bis = v_heute + 7 and p.art in ('paket','bonus') loop
      if r.rest > 0 then
        perform push_an(r.kunde, 'ablauf', 'Credits laufen bald ab', trim(to_char(r.rest, 'FM999990.##')) || ' Credits gelten nur noch bis ' || to_char(r.gueltig_bis, 'DD.MM.') || '.', null, 'c' || r.id);
      end if;
    end loop;
    -- Offene Zahlungen (angefragte Buchungen)
    select count(*) into v_anzahl from buchungen where status = 'angefragt';
    if v_anzahl > 0 then
      perform push_an_team('zahlung', 'Zahlungen offen', v_anzahl || case when v_anzahl = 1 then ' Anfrage wartet' else ' Anfragen warten' end || ' auf Zahlung oder Bestätigung.', 'z' || v_heute);
    end if;
    -- Am 1.: Partner-Abrechnung des Vormonats zur Prüfung
    if extract(day from v_heute) = 1 then
      perform push_an_partner('basement', 'abrechnung', 'Abrechnung bereit', 'Ihre Abrechnung für ' || to_char(v_heute - 1, 'MM/YYYY') || ' liegt zur Prüfung in der App.', 'r' || v_heute);
      perform push_an_partner('blackclouds', 'abrechnung', 'Abrechnung bereit', 'Ihre Abrechnung für ' || to_char(v_heute - 1, 'MM/YYYY') || ' liegt zur Prüfung in der App.', 'r' || v_heute);
    end if;
  end if;

  -- Liegengebliebenes nachschieben
  if exists (select 1 from push_warteschlange where gesendet_am is null) then perform push_anstossen(); end if;
  -- Aufräumen
  delete from push_warteschlange where erstellt_am < now() - interval '30 days';
end $$;

-- ---------- Für die App ----------
create or replace function push_abo_speichern(p_endpoint text, p_p256dh text, p_auth text, p_geraet text default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'KEIN_ZUGRIFF'; end if;
  insert into push_abos(nutzer, endpoint, p256dh, auth, geraet) values (auth.uid(), p_endpoint, p_p256dh, p_auth, left(p_geraet, 120))
  on conflict (endpoint) do update set nutzer = excluded.nutzer, p256dh = excluded.p256dh, auth = excluded.auth, geraet = excluded.geraet;
  perform log_aktion('push_an', jsonb_build_object('geraet', left(p_geraet, 60)));
end $$;

create or replace function push_abo_loeschen(p_endpoint text) returns void
language plpgsql security definer set search_path = public as $$
begin
  delete from push_abos where endpoint = p_endpoint and nutzer = auth.uid();
end $$;

create or replace function push_einstellungen_setzen(p_aus text[]) returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'KEIN_ZUGRIFF'; end if;
  insert into push_einstellungen(nutzer, aus) values (auth.uid(), coalesce(p_aus, '{}'))
  on conflict (nutzer) do update set aus = excluded.aus;
end $$;

create or replace function push_status() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'aus', coalesce((select to_jsonb(aus) from push_einstellungen where nutzer = auth.uid()), '[]'::jsonb),
    'geraete', (select count(*) from push_abos where nutzer = auth.uid()),
    'endpoints', coalesce((select jsonb_agg(endpoint) from push_abos where nutzer = auth.uid()), '[]'::jsonb))
$$;

create or replace function push_test() returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'KEIN_ZUGRIFF'; end if;
  if not exists (select 1 from push_abos where nutzer = auth.uid()) then raise exception 'KEIN_GERAET'; end if;
  insert into push_warteschlange(nutzer, art, titel, text)
  values (auth.uid(), 'test', 'CloudStudios', 'Push-Mitteilungen sind eingeschaltet. ⚡');
end $$;

-- Schlüsselpaar für den Versand: erzeugt die Versandfunktion selbst beim ersten Lauf.
-- Der private Teil ist nur mit dem Service-Schlüssel lesbar; die App bekommt nur den öffentlichen.
create table if not exists push_schluessel (
  id          int primary key default 1 check (id = 1),
  oeffentlich text not null,
  privat      text not null,
  erstellt_am timestamptz not null default now()
);
alter table push_schluessel enable row level security;
revoke all on push_schluessel from anon, authenticated;
grant all on push_schluessel to service_role;
create or replace function push_oeffentlich() returns text
language sql stable security definer set search_path = public as $$ select oeffentlich from push_schluessel where id = 1 $$;
grant execute on function push_oeffentlich to authenticated;

-- Für die Versandfunktion: offene Einträge atomar übernehmen (kein Doppelversand)
create or replace function push_holen(p_max int default 200)
returns table(id bigint, nutzer uuid, art text, titel text, text text, url text)
language sql security definer set search_path = public as $$
  update push_warteschlange w set gesendet_am = now()
   where w.id in (select x.id from push_warteschlange x where x.gesendet_am is null order by x.id limit p_max for update skip locked)
  returning w.id, w.nutzer, w.art, w.titel, w.text, w.url
$$;
revoke execute on function push_holen from public, anon, authenticated;
grant execute on function push_holen to service_role;

revoke all on push_abos, push_einstellungen, push_warteschlange from anon, authenticated;
revoke execute on function push_an, push_an_team, push_an_partner, push_anstossen, push_zeitplan from public, anon, authenticated;
grant execute on function push_abo_speichern, push_abo_loeschen, push_einstellungen_setzen, push_status, push_test to authenticated;
grant all on push_abos, push_einstellungen, push_warteschlange to service_role;
grant usage, select on all sequences in schema public to service_role;
