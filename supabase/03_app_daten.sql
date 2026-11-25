-- CloudStudios Studio-App · 03_app_daten.sql
-- Eine Abfrage für die App: liefert alles, was die angemeldete Person sehen darf, als JSON.
create or replace function app_daten(p_von timestamptz default now() - interval '2 days',
                                     p_bis timestamptz default now() + interval '100 days')
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_rolle text := meine_rolle(); v_partner text := mein_partner(); v_team boolean := ist_team();
  v_admin boolean := meine_rolle() = 'admin'; v_ich uuid := auth.uid(); v_heute date := berlin_datum(now());
  r jsonb := '{}'::jsonb;
begin
  if v_rolle is null then raise exception 'NICHT_ANGEMELDET'; end if;

  r := r || jsonb_build_object('ich', (select jsonb_build_object('id', id, 'rolle', rolle, 'partner', partner,
          'team_rolle', team_rolle, 'name', name, 'kn', kn,
          'mail', (select email from auth.users u where u.id = p.id)) from profiles p where id = v_ich));

  -- Kunden mit aktueller Mitgliedschaft
  r := r || jsonb_build_object('kunden', coalesce((select jsonb_agg(jsonb_build_object(
          'id', p.id, 'name', p.name, 'kn', p.kn, 'tel', case when v_team or p.id = v_ich then p.telefon end, 'aktiv', p.aktiv,
          'notiz', case when v_team then p.notiz end,
          'seit', to_char(p.erstellt_am, 'MM/YYYY'),
          'mail', case when v_team then (select email from auth.users u where u.id = p.id) end,
          'mitglied', (select m.tarif from mitgliedschaften m where m.kunde = p.id and m.aktiv_ab <= v_heute
                         and (m.aktiv_bis is null or m.aktiv_bis >= v_heute) order by m.aktiv_ab desc limit 1),
          'tarif_id', (select m.tarif_id from mitgliedschaften m where m.kunde = p.id and m.aktiv_ab <= v_heute
                         and (m.aktiv_bis is null or m.aktiv_bis >= v_heute) order by m.aktiv_ab desc limit 1),
          'basement', exists (select 1 from mitgliedschaften m where m.kunde = p.id and m.basement_pauschale
                         and (m.aktiv_bis is null or m.aktiv_bis >= v_heute)),
          'label', exists (select 1 from credit_posten c where c.kunde = p.id and c.art = 'label' and c.gueltig_bis >= v_heute)
        ) order by p.kn nulls last, p.name)
        from profiles p where p.rolle = 'kunde' and (v_team or p.id = v_ich
          or (v_partner = 'blackclouds' and (exists (select 1 from bewerbungen w where w.kunde = p.id)
                                             or exists (select 1 from freigaben f where f.kunde = p.id)))
          or (v_partner = 'basement' and exists (select 1 from mitgliedschaften m where m.kunde = p.id and m.basement_pauschale
                                                  and (m.aktiv_bis is null or m.aktiv_bis >= v_heute))))), '[]'::jsonb));

  -- Team und Partner-Zugänge (nur Admin)
  if v_admin then
    r := r || jsonb_build_object('konten', coalesce((select jsonb_agg(jsonb_build_object(
            'id', p.id, 'name', p.name, 'rolle', p.rolle, 'team_rolle', p.team_rolle, 'partner', p.partner, 'aktiv', p.aktiv,
            'mail', (select email from auth.users u where u.id = p.id)) order by p.rolle, p.name)
          from profiles p where p.rolle in ('admin','team','partner')), '[]'::jsonb));
  end if;

  -- Credit-Posten mit Rest
  r := r || jsonb_build_object('posten', coalesce((select jsonb_agg(jsonb_build_object(
          'id', c.id, 'kunde', c.kunde, 'art', c.art, 'credits', c.credits, 'rest', posten_rest(c.id),
          'ab', c.gueltig_ab, 'bis', c.gueltig_bis, 'nur', c.nur_studios, 'rn', c.rechnung, 'notiz', c.notiz) order by c.gueltig_bis, c.id)
        from credit_posten c where c.gueltig_bis >= v_heute - 1 and (v_team or c.kunde = v_ich)), '[]'::jsonb));

  -- Buchungen
  if v_team then
    r := r || jsonb_build_object('buchungen', coalesce((select jsonb_agg(jsonb_build_object(
            'id', b.id, 'studio', b.studio, 'beginn', lower(b.zeitraum), 'ende', upper(b.zeitraum), 'status', b.status,
            'kunde', b.kunde, 'gast', b.gast_name, 'kn', coalesce(b.kn, (select kn from profiles where id = b.kunde)),
            'credits', b.credits, 'preis', b.preis_brutto, 'reserviert_bis', b.reserviert_bis, 'angebot', b.angebot,
            'rechnung', b.rechnung, 'erstattet', b.erstattet, 'grund', b.grund, 'partner', b.eigennutzung_partner,
            'gruppe', b.gruppe, 'noshow', b.nicht_erschienen, 'notiz', b.notiz, 'storniert_am', b.storniert_am,
            'storniert_von', (select name from profiles where id = b.storniert_von)) order by lower(b.zeitraum))
          from buchungen b where b.zeitraum && tstzrange(p_von, p_bis)), '[]'::jsonb));
  else
    r := r || jsonb_build_object('buchungen', coalesce((select jsonb_agg(x order by x->>'beginn') from (
            select jsonb_build_object('id', b.id, 'studio', b.studio, 'beginn', lower(b.zeitraum), 'ende', upper(b.zeitraum),
              'status', b.status, 'kunde', b.kunde, 'credits', b.credits, 'erstattet', b.erstattet, 'grund', b.grund,
              'partner', b.eigennutzung_partner, 'storniert_am', b.storniert_am, 'eigen', true) x
              from buchungen b where b.zeitraum && tstzrange(p_von, p_bis)
               and (b.kunde = v_ich or (v_partner is not null and b.eigennutzung_partner = v_partner))
            union all
            select jsonb_build_object('id', k.id, 'studio', k.studio, 'beginn', k.beginn, 'ende', k.ende,
              'status', case k.farbe when 'gruen' then 'angefragt' when 'rot' then 'geschlossen' when 'grau' then 'blockiert' else 'gebucht' end,
              'kunde', null, 'credits', 0, 'erstattet', false, 'grund', k.titel, 'lila', k.farbe = 'lila', 'eigen', false)
              from kalender(p_von, p_bis) k
             where not exists (select 1 from buchungen b where b.id = k.id
                                and (b.kunde = v_ich or (v_partner is not null and b.eigennutzung_partner = v_partner)))
          ) s), '[]'::jsonb));
  end if;

  -- Anfragen, Bewerbungen, Freigaben
  r := r || jsonb_build_object('anfragen', coalesce((select jsonb_agg(jsonb_build_object(
          'id', a.id, 'kunde', a.kunde, 'studio', a.studio, 'text', a.wunsch, 'status', a.status, 'am', a.erstellt_am, 'art', a.art, 'daten', a.daten) order by a.id desc)
        from anfragen a where (v_team or a.kunde = v_ich) and (a.status in ('offen','in_klaerung') or a.erstellt_am > now() - interval '14 days')), '[]'::jsonb));
  r := r || jsonb_build_object('bewerbungen', coalesce((select jsonb_agg(to_jsonb(b) order by b.id desc)
        from bewerbungen b where v_team or v_partner = 'blackclouds' or b.kunde = v_ich), '[]'::jsonb));
  r := r || jsonb_build_object('freigaben', coalesce((select jsonb_agg(jsonb_build_object('kunde', f.kunde, 'studio', f.studio,
          'name', (select name from profiles where id = f.kunde), 'kn', (select kn from profiles where id = f.kunde)))
        from freigaben f where v_team or v_partner = 'blackclouds' or f.kunde = v_ich), '[]'::jsonb));

  -- Partner: Mitteilungen, Zustandsmeldungen, Gutschrift-Bestätigungen
  if v_team or v_partner is not null then
    r := r || jsonb_build_object('mitteilungen', coalesce((select jsonb_agg(jsonb_build_object('id', m.id, 'partner', m.partner,
            'von', case when m.vom_partner then (case m.partner when 'basement' then 'Basement Studios' else 'BlackClouds' end) else 'CloudStudios' end,
            'text', m.text, 'am', m.am, 'gelesen', m.gelesen) order by m.am)
          from mitteilungen m where v_team or m.partner = v_partner), '[]'::jsonb));
    r := r || jsonb_build_object('zustand', coalesce((select jsonb_agg(jsonb_build_object('id', z.id, 'partner', z.partner, 'raum', z.raum,
            'text', z.text, 'foto', z.foto_pfad, 'buchung', z.buchung, 'status', z.status, 'am', z.am,
            'kunde', (select b.kunde from buchungen b where b.id = z.buchung)) order by z.am desc)
          from zustandsmeldungen z where (v_team or z.partner = v_partner) and (z.status = 'offen' or z.am > now() - interval '30 days')), '[]'::jsonb));
    r := r || jsonb_build_object('gutschriften', coalesce((select jsonb_agg(to_jsonb(g))
          from gutschrift_bestaetigungen g where v_admin or g.partner = v_partner), '[]'::jsonb));
  end if;

  -- Einstellungen, Rechte, Tarife
  r := r || jsonb_build_object('einstellungen', coalesce((select jsonb_object_agg(schluessel, wert) from einstellungen), '{}'::jsonb));
  r := r || jsonb_build_object('tarife', coalesce((select jsonb_agg(to_jsonb(t) order by t.id) from tarife t where t.aktiv), '[]'::jsonb));
  if v_team then
    r := r || jsonb_build_object('rechte', coalesce((select jsonb_object_agg(rolle, l) from
            (select rolle, jsonb_agg(recht) l from rollen_rechte group by rolle) x), '{}'::jsonb));
    r := r || jsonb_build_object('meine_rechte', coalesce((select jsonb_agg(x) from unnest(array['kalender','eintragen','anfragen','kunden','codes',
            'aufladen','kulanz','zahlen','abrechnung','konten','einstellungen']) x where darf(x)), '[]'::jsonb));
  end if;
  if v_admin then
    r := r || jsonb_build_object('protokoll', coalesce((select jsonb_agg(jsonb_build_object('am', l.am, 'wer', coalesce(p.name, 'System'),
            'aktion', l.aktion, 'details', l.details) order by l.id desc)
          from (select * from protokoll order by id desc limit 200) l left join profiles p on p.id = l.von), '[]'::jsonb));
  end if;
  r := r || jsonb_build_object('codes', meine_codes());
  return r;
end $$;
grant execute on function app_daten(timestamptz, timestamptz) to authenticated;

-- Admin: Kundenstammdaten (Telefon, Notiz) pflegen
alter table profiles add column if not exists notiz text;
create or replace function kunde_notiz(p_kunde uuid, p_notiz text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not darf('kunden') then raise exception 'KEIN_ZUGRIFF'; end if;
  update profiles set notiz = p_notiz where id = p_kunde;
end $$;
grant execute on function kunde_notiz(uuid, text) to authenticated;

-- Mitteilungen als gelesen markieren
create or replace function mitteilungen_gelesen(p_partner text) returns void
language plpgsql security definer set search_path = public as $$
declare v_partner text := mein_partner();
begin
  if v_partner is not null then
    update mitteilungen set gelesen = true where partner = v_partner and not vom_partner;
  elsif ist_team() then
    update mitteilungen set gelesen = true where partner = p_partner and vom_partner;
  else raise exception 'KEIN_ZUGRIFF'; end if;
end $$;
grant execute on function mitteilungen_gelesen(text) to authenticated;

-- Anfrage-Status setzen (Team)
create or replace function anfrage_status(p_id bigint, p_status text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not darf('anfragen') then raise exception 'KEIN_ZUGRIFF'; end if;
  update anfragen set status = p_status where id = p_id;
  perform log_aktion('anfrage_status', jsonb_build_object('anfrage', p_id, 'status', p_status));
end $$;
grant execute on function anfrage_status(bigint, text) to authenticated;

-- Anfragen mit Art und Zusatzdaten (Paket, Veranstaltung, Shop, Problem)
alter table anfragen add column if not exists art text not null default 'problem';
alter table anfragen add column if not exists daten jsonb;
create or replace function anfrage_neu(p_art text, p_text text, p_daten jsonb default null, p_studio text default null)
returns bigint
language plpgsql security definer set search_path = public as $$
declare v_id bigint;
begin
  if meine_rolle() is null then raise exception 'NICHT_ANGEMELDET'; end if;
  if p_art not in ('paket','event','bestellung','problem','s5') then raise exception 'UNGUELTIGE_ART'; end if;
  if p_text is null or length(trim(p_text)) < 3 then raise exception 'TEXT_FEHLT'; end if;
  insert into anfragen(kunde, studio, wunsch, art, daten) values (auth.uid(), p_studio, p_text, p_art, p_daten) returning id into v_id;
  perform log_aktion('anfrage_neu', jsonb_build_object('anfrage', v_id, 'art', p_art));
  return v_id;
end $$;
grant execute on function anfrage_neu(text, text, jsonb, text) to authenticated;

-- Türcodes pro Tag (WeLock). Kunden sehen den Code nur an Tagen mit eigener Buchung.
create table if not exists tuercodes (
  tag   date primary key,
  code  text not null,
  von   uuid references profiles(id),
  am    timestamptz not null default now()
);
alter table tuercodes enable row level security;
create or replace function tuercode_setzen(p_tag date, p_code text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not darf('codes') then raise exception 'KEIN_ZUGRIFF'; end if;
  if coalesce(trim(p_code), '') = '' then delete from tuercodes where tag = p_tag;
  else insert into tuercodes(tag, code, von) values (p_tag, trim(p_code), auth.uid())
       on conflict (tag) do update set code = excluded.code, von = excluded.von, am = now(); end if;
  perform log_aktion('tuercode_setzen', jsonb_build_object('tag', p_tag));
end $$;
grant execute on function tuercode_setzen(date, text) to authenticated;
create or replace function meine_codes() returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_object_agg(t.tag, t.code), '{}'::jsonb) from tuercodes t
   where t.tag between berlin_datum(now()) and berlin_datum(now()) + 30
     and (darf('codes') or exists (select 1 from buchungen b where b.kunde = auth.uid() and b.status = 'gebucht'
                                    and berlin_datum(lower(b.zeitraum)) = t.tag))
$$;
grant execute on function meine_codes() to authenticated;

-- Nur angemeldete Nutzer
revoke execute on function app_daten(timestamptz, timestamptz), kunde_notiz(uuid, text), mitteilungen_gelesen(text), anfrage_status(bigint, text), anfrage_neu(text, text, jsonb, text), tuercode_setzen(date, text), meine_codes() from public, anon;
revoke all on table tuercodes from anon, authenticated;

-- Server-Funktion "einladen" arbeitet mit der Service-Rolle (Projekt ohne automatische API-Rechte angelegt)
grant usage on schema public to service_role;
grant all on all tables in schema public to service_role;
grant all on all sequences in schema public to service_role;
grant execute on all functions in schema public to service_role;
alter default privileges in schema public grant all on tables to service_role;
alter default privileges in schema public grant all on sequences to service_role;
