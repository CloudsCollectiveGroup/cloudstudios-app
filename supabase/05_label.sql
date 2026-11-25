-- ============================================================
-- CloudStudios · Clouds Records: Label-Credits (Stand 25.11.2026)
-- Artist 30, Producer 60 Credits im Monat, nur Studio 1, gültig bis Monatsende.
-- Verrechnet wird nur, was eingelöst wurde: 5,00 € netto je Credit (Vorschuss).
-- Nachbuchen zu denselben Bedingungen: Anfrage in der App, Freigabe durch Cem.
-- ============================================================

insert into tarife (id,name,art,credits_monat,beitrag_brutto,nur_studios,partner_max_monat,nur_einladung) values
  ('Label 30','Clouds Records · Artist','label',30,0,array['s1'],null,false),
  ('Label 60','Clouds Records · Producer','label',60,0,array['s1'],null,false)
on conflict (id) do update set name = excluded.name, credits_monat = excluded.credits_monat, aktiv = true;
update tarife set aktiv = false where id = 'Label 20';

insert into einstellungen(schluessel, wert) values ('label_wert_netto', to_jsonb(5.00))
on conflict (schluessel) do nothing;

-- Eingelöste Label-Credits je Person und Monat (Grundlage der Vorschuss-Verrechnung)
-- Gezählt wird, was angerechnet wurde: durchgeführte Sessions und späte Stornos (halbe Credits).
create or replace function label_verbrauch(p_monat date)
returns table(kunde uuid, name text, kn text, tarif text, credits numeric, betrag_netto numeric, betrag_brutto numeric)
language plpgsql stable security definer set search_path = public as $$
declare v_von date := date_trunc('month', p_monat)::date; v_bis date := monatsende(p_monat);
        v_wert numeric := coalesce((select (wert #>> '{}')::numeric from einstellungen where schluessel = 'label_wert_netto'), 5);
begin
  if meine_rolle() <> 'admin' and not darf('abrechnung') then raise exception 'KEIN_ZUGRIFF'; end if;
  return query
  select pr.id, pr.name, pr.kn,
         coalesce((select t.name from mitgliedschaften m join tarife t on t.id = m.tarif_id
                    where m.kunde = pr.id and t.art = 'label' order by m.aktiv_ab desc limit 1), 'Clouds Records'),
         sum(z.credits), round(sum(z.credits) * v_wert, 2), round(sum(z.credits) * v_wert * 1.19, 2)
    from zuordnungen z
    join credit_posten p on p.id = z.posten
    join buchungen b on b.id = z.buchung
    join profiles pr on pr.id = p.kunde
   where p.art = 'label' and not b.erstattet and b.status in ('gebucht','storniert')
     and berlin_datum(lower(b.zeitraum)) between v_von and v_bis
   group by pr.id, pr.name, pr.kn
   order by pr.name;
end $$;
revoke execute on function label_verbrauch(date) from public, anon;
grant execute on function label_verbrauch(date) to authenticated;

-- Nachbuchen: Label-Leute fragen weitere Label-Credits an (Anfrage-Art 'label')
create or replace function anfrage_neu(p_art text, p_text text, p_daten jsonb default null, p_studio text default null)
returns bigint
language plpgsql security definer set search_path = public as $$
declare v_id bigint;
begin
  if meine_rolle() is null then raise exception 'NICHT_ANGEMELDET'; end if;
  if p_art not in ('paket','event','bestellung','problem','s5','label') then raise exception 'UNGUELTIGE_ART'; end if;
  if p_art = 'label' and not exists (select 1 from mitgliedschaften m join tarife t on t.id = m.tarif_id where m.kunde = auth.uid() and t.art = 'label' and (m.aktiv_bis is null or m.aktiv_bis >= current_date)) then raise exception 'KEIN_ZUGRIFF'; end if;
  if p_text is null or length(trim(p_text)) < 3 then raise exception 'TEXT_FEHLT'; end if;
  insert into anfragen(kunde, studio, wunsch, art, daten) values (auth.uid(), p_studio, p_text, p_art, p_daten) returning id into v_id;
  perform log_aktion('anfrage_neu', jsonb_build_object('anfrage', v_id, 'art', p_art));
  return v_id;
end $$;
