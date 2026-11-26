-- 07 · Clouds Records: Producer bucht für Label-Artists (26.11.2026)
-- Anuj (KN - 002) darf Sessions für Artists mit Label-Credits eintragen; abgezogen werden nur deren Label-Credits.

-- Clouds Records: Producer mit Label-Recht darf für Label-Artists buchen (Stand 26.11.2026)
alter table profiles add column if not exists label_bucher boolean not null default false;
create or replace function darf_fuer_artist(p_artist uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select p_artist is not null and p_artist <> auth.uid()
     and exists (select 1 from profiles me where me.id = auth.uid() and me.aktiv and me.label_bucher)
     and exists (select 1 from profiles a where a.id = p_artist and a.aktiv and a.rolle = 'kunde')
     and exists (select 1 from credit_posten c where c.kunde = p_artist and c.art = 'label' and c.gueltig_bis >= berlin_datum(now()))
$$;

create or replace function credits_buchen(p_studio text, p_start timestamptz, p_stunden numeric, p_kunde uuid default null, p_notiz text default null)
returns bigint
language plpgsql security definer set search_path = public as $$
declare
  v_rolle text := meine_rolle();
  v_kunde uuid;
  v_st studios;
  v_bedarf numeric; v_offen numeric; v_nimm numeric; v_verfuegbar numeric;
  v_tag date; v_id bigint; r record; v_fuer boolean := false;
begin
  if v_rolle is null then raise exception 'NICHT_ANGEMELDET'; end if;
  if v_rolle = 'kunde' then
    if p_kunde is not null and p_kunde <> auth.uid() then
      -- Producer mit Label-Recht bucht für einen Clouds-Records-Artist (nur dessen Label-Credits)
      if not darf_fuer_artist(p_kunde) then raise exception 'KEIN_ZUGRIFF'; end if;
      v_kunde := p_kunde; v_fuer := true;
    else
      v_kunde := auth.uid();
    end if;
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
   where p.gueltig_ab <= berlin_datum(p_start) and (not v_fuer or p.art = 'label');
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
            where p.gueltig_ab <= berlin_datum(p_start) and (not v_fuer or p.art = 'label') loop
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

create or replace function stornieren(p_buchung bigint, p_kulanz boolean default false)
returns text
language plpgsql security definer set search_path = public as $$
declare v_rolle text := meine_rolle(); b buchungen; v_erstatten boolean; v_mitglied boolean; v_frist interval; v_halb numeric;
begin
  if v_rolle is null then raise exception 'NICHT_ANGEMELDET'; end if;
  select * into b from buchungen where id = p_buchung for update;
  if not found then raise exception 'NICHT_GEFUNDEN'; end if;
  if v_rolle = 'kunde' and b.kunde is distinct from auth.uid()
     and not (b.erstellt_von = auth.uid() and darf_fuer_artist(b.kunde)) then raise exception 'KEIN_ZUGRIFF'; end if;
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

create or replace function app_daten(p_von timestamptz default now() - interval '2 days',
                                     p_bis timestamptz default now() + interval '100 days')
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_rolle text := meine_rolle(); v_partner text := mein_partner(); v_team boolean := ist_team();
  v_admin boolean := meine_rolle() = 'admin'; v_ich uuid := auth.uid(); v_heute date := berlin_datum(now());
  v_lb boolean := coalesce((select label_bucher from profiles where id = auth.uid()), false);
  r jsonb := '{}'::jsonb;
begin
  if v_rolle is null then raise exception 'NICHT_ANGEMELDET'; end if;

  r := r || jsonb_build_object('ich', (select jsonb_build_object('id', id, 'rolle', rolle, 'partner', partner,
          'team_rolle', team_rolle, 'name', name, 'kn', kn, 'label_bucher', label_bucher,
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
        from profiles p where p.rolle = 'kunde' and (v_team or p.id = v_ich or (v_lb and darf_fuer_artist(p.id))
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
        from credit_posten c where c.gueltig_bis >= v_heute - 1 and (v_team or c.kunde = v_ich
          or (v_lb and c.art = 'label' and darf_fuer_artist(c.kunde)))), '[]'::jsonb));

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
               and (b.kunde = v_ich or (v_lb and b.erstellt_von = v_ich and b.kunde is not null) or (v_partner is not null and b.eigennutzung_partner = v_partner))
            union all
            select jsonb_build_object('id', k.id, 'studio', k.studio, 'beginn', k.beginn, 'ende', k.ende,
              'status', case k.farbe when 'gruen' then 'angefragt' when 'rot' then 'geschlossen' when 'grau' then 'blockiert' else 'gebucht' end,
              'kunde', null, 'credits', 0, 'erstattet', false, 'grund', k.titel, 'lila', k.farbe = 'lila', 'eigen', false)
              from kalender(p_von, p_bis) k
             where not exists (select 1 from buchungen b where b.id = k.id
                                and (b.kunde = v_ich or (v_lb and b.erstellt_von = v_ich and b.kunde is not null) or (v_partner is not null and b.eigennutzung_partner = v_partner)))
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

update profiles set label_bucher = true where kn = 'KN - 002' and name = 'Anuj Rajan';
