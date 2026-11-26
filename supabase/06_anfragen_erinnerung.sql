-- 06 · Walk-In-Anfragen: nicht mehr still verfallen lassen (26.11.2026)
-- 1) Reservierung mindestens 3 Stunden ab Eintrag – auch wenn der Start schon vorbei ist (Nachtrag).
-- 2) Erinnerung ans Team, wenn eine Anfrage in den nächsten 3 Stunden verfällt.
-- 3) Meldung ans Team, wenn eine Anfrage verfallen ist.

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
            greatest(p_start - interval '24 hours', least(now() + interval '24 hours', p_start), now() + interval '3 hours'),
            auth.uid(), p_notiz)
    returning id into v_id;
  exception when exclusion_violation then raise exception 'SLOT_BELEGT';
  end;
  perform log_aktion('anfrage_eintragen', jsonb_build_object('buchung', v_id, 'studio', p_studio, 'start', p_start));
  return v_id;
end $$;

-- Erinnerung: läuft alle 5 Minuten über push_zeitplan()
create or replace function push_anfragen_erinnern() returns void
language plpgsql security definer set search_path = public as $$
declare r record;
begin
  for r in select b.id, b.reserviert_bis, b.zeitraum, s.name as studio, coalesce(p.name, b.gast_name, 'Walk-In') as wer
             from buchungen b join studios s on s.id = b.studio left join profiles p on p.id = b.kunde
            where b.status = 'angefragt' and b.reserviert_bis > now() and b.reserviert_bis <= now() + interval '3 hours' loop
    perform push_an_team('zahlung', 'Anfrage läuft ab',
      r.wer || ' · ' || r.studio || ' · ' || push_zeit(lower(r.zeitraum)) || ' – bis ' || to_char(r.reserviert_bis at time zone 'Europe/Berlin', 'HH24:MI') || ' Uhr bestätigen, sonst wird der Slot frei.',
      'ae' || r.id);
  end loop;
end $$;
revoke execute on function push_anfragen_erinnern from authenticated;

-- In den 5-Minuten-Lauf einhängen (Rest von push_zeitplan unverändert)
create or replace function push_zeitplan() returns void
language plpgsql security definer set search_path = public as $$
declare r record; v_jetzt timestamptz := now(); v_heute date := (now() at time zone 'Europe/Berlin')::date; v_anzahl int;
begin
  for r in select b.id, b.kunde, b.zeitraum, s.name from buchungen b join studios s on s.id = b.studio
            where b.status = 'gebucht' and b.kunde is not null
              and lower(b.zeitraum) > v_jetzt + interval '22 hours' and lower(b.zeitraum) <= v_jetzt + interval '24 hours' loop
    perform push_an(r.kunde, 'verbindlich', 'Buchung ist verbindlich', r.name || ' · ' || push_zeit(lower(r.zeitraum)) || ' – Ihren Türcode finden Sie in der App.', null, 'v' || r.id);
  end loop;

  perform push_anfragen_erinnern();

  if extract(hour from now() at time zone 'Europe/Berlin') >= 10 then
    for r in select p.id, p.kunde, p.gueltig_bis, posten_rest(p.id) as rest from credit_posten p
              where p.gueltig_bis = v_heute + 7 and p.art in ('paket','bonus') loop
      if r.rest > 0 then
        perform push_an(r.kunde, 'ablauf', 'Credits laufen bald ab', trim(to_char(r.rest, 'FM999990.##')) || ' Credits gelten nur noch bis ' || to_char(r.gueltig_bis, 'DD.MM.') || '.', null, 'c' || r.id);
      end if;
    end loop;
    select count(*) into v_anzahl from buchungen where status = 'angefragt';
    if v_anzahl > 0 then
      perform push_an_team('zahlung', 'Zahlungen offen', v_anzahl || case when v_anzahl = 1 then ' Anfrage wartet' else ' Anfragen warten' end || ' auf Zahlung oder Bestätigung.', 'z' || v_heute);
    end if;
    if extract(day from v_heute) = 1 then
      perform push_an_partner('basement', 'abrechnung', 'Abrechnung bereit', 'Ihre Abrechnung für ' || to_char(v_heute - 1, 'MM/YYYY') || ' liegt zur Prüfung in der App.', 'r' || v_heute);
      perform push_an_partner('blackclouds', 'abrechnung', 'Abrechnung bereit', 'Ihre Abrechnung für ' || to_char(v_heute - 1, 'MM/YYYY') || ' liegt zur Prüfung in der App.', 'r' || v_heute);
    end if;
  end if;

  if exists (select 1 from push_warteschlange where gesendet_am is null) then perform push_anstossen(); end if;
  delete from push_warteschlange where erstellt_am < now() - interval '30 days';
end $$;

-- Team-Meldung beim Verfallen
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
      perform push_an_team('zahlung', 'Anfrage verfallen', v_wer || ' · ' || v_studio || ' · ' || v_wann || ' – nicht bestätigt, Slot ist wieder frei.', 'bv' || new.id);
    end if;
  end if;
  return new;
end $$;
drop trigger if exists push_buchung on buchungen;
create trigger push_buchung after insert or update of status on buchungen for each row execute function push_buchung();

