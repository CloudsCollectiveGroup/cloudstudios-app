# CloudStudios – Studio-App

Buchungs-App für CloudStudios mit Credit-Konten. Aufbau wie die Clouds-Records-App:
`index.html` auf GitHub Pages, Daten und Login über Supabase (Region Frankfurt).

## Stand
- Phase 1 (Datenbank, Regeln, Tests): fertig
- Phase 2–6: folgen (Team-Cockpit, Kunden-Ansicht, Partner-Bereich, Testphase, Start)

## Aufbau
- `supabase/01_schema.sql` – Tabellen, Zugriffsregeln, Buchungslogik
- `supabase/02_zeitplan.sql` – automatische Läufe (Verfall, Monatsguthaben, Anfragen freigeben)
- `tests/` – automatische Tests der Buchungslogik (nur lokal, nicht in Supabase ausführen)

## Einrichtung (einmalig)
1. Supabase-Projekt „cloudstudios“, Region Frankfurt (eu-central-1)
2. Database → Extensions: `pg_cron` aktivieren
3. SQL-Editor: erst `01_schema.sql`, dann `02_zeitplan.sql`
4. Authentication → Providers → Email: „Allow new users to sign up“ AUS, „Confirm email“ AUS
5. Erster Benutzer (Cem): Authentication → Users → Add user, „Auto Confirm“ an. Danach im SQL-Editor:
   `update profiles set rolle = 'admin' where id = '<ID aus Users>';`

## Regeln (in der Datenbank, nicht umgehbar)
- Credits je Stunde: Studio 1 und 3 = 1, Studio 4 = 2, Studio 5 = 4,5
- Mindestens 2 Stunden; Buchung nur mit Deckung, sonst Vorschlag der möglichen Stunden
- Credits gehen bei Buchung ab; Storno mehr als 24 Std. vorher → zurück
- Studio 5 nur durch das Team
- Doppelbuchungen technisch ausgeschlossen
- Älteste Credits zuerst; Paket 3 Monate ab Zahlungseingang; Mitglieds-, Label- und Basement-Credits bis Monatsende
- Kontostand nur über Funktionen änderbar, jede Aktion im Protokoll

## Tests lokal
```
python3 tests/test_buchungslogik.py
```
