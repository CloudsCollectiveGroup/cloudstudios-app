# CloudStudios – Studio-App

Buchungs-App für CloudStudios mit Credit-Konten. Aufbau wie die Clouds-Records-App:
`index.html` auf GitHub Pages, Daten und Login über Supabase (Region Frankfurt).

## Stand
- Phase 1 (Datenbank, Regeln, Tests): fertig, erweitert am 24.11.2026 (115 Tests)
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
6. Weitere Konten legt Cem in der App an (Mehr → Konten). Die App verschickt dafür eine Einladung über
   eine kleine Supabase-Funktion („einladen“, kommt in Phase 2), weil Einladungen den geheimen Server-Schlüssel brauchen.
7. Storage: Bucket `zustand` (privat) für Fotos von Zustandsmeldungen.

## Regeln (in der Datenbank, nicht umgehbar)
- Credits je Stunde: Studio 1 und 3 = 1, Studio 4 = 2, Studio 5 = 4,5
- Mindestens 2 Stunden; Buchung nur mit Deckung, sonst Vorschlag der möglichen Stunden
- Credits gehen bei Buchung ab; Storno mehr als 24 Std. vorher → zurück
- Studio 5: Bewerbung des Kunden, Entscheidung durch BlackClouds; dauerhaft Freigegebene buchen selbst
- PA 220: höchstens 30 Credits pro Monat in Partnerstudios (in der Tabelle `tarife` änderbar)
- Veranstaltung sperrt Lounge und Studio 1 gemeinsam
- Team-Rechte je Rolle (`rollen_rechte`), Admin darf alles; „Credits aufladen“ ist anfangs bei niemandem an
- Gesperrte Konten (`profiles.aktiv = false`) können sich nicht anmelden und nicht buchen
- Puffer: Wechselzeit ist in der Stunde enthalten, räumen bis :45 (Anzeige in der App)
- Doppelbuchungen technisch ausgeschlossen
- Älteste Credits zuerst; Paket 3 Monate ab Zahlungseingang; Mitglieds-, Label- und Basement-Credits bis Monatsende
- Kontostand nur über Funktionen änderbar, jede Aktion im Protokoll

## Tests lokal
```
python3 tests/test_buchungslogik.py
```
