# CloudStudios – Studio-App

Buchungs-App für CloudStudios mit Credit-Konten. Aufbau wie die Clouds-Records-App:
`index.html` auf GitHub Pages, Daten und Login über Supabase (Region Frankfurt).

## Stand (25.11.2026)
- Datenbank mit Regeln: fertig und in Supabase eingespielt (140 Tests)
- App: live unter https://cloudscollectivegroup.github.io/cloudstudios-app/ (Team, Kunde, Partner)
- Einladungen: Funktion `einladen` erzeugt einen persönlichen Link, das Team schickt ihn per WhatsApp
- Offen: Testphase mit echten Konten, danach Ankündigung an Kunden

## Aufbau
- `supabase/01_schema.sql` – Tabellen, Zugriffsregeln, Buchungslogik
- `supabase/02_zeitplan.sql` – automatische Läufe (Verfall, Monatsguthaben, Anfragen freigeben)
- `supabase/03_app_daten.sql` – eine Abfrage pro Ansicht (`app_daten`), Türcodes, Anfragen mit Art
- `supabase/functions/einladen/` – Konto anlegen und Einladungs- bzw. Passwort-Link erzeugen
- `docs/` – die App (GitHub Pages): `index.html` (Oberfläche aus dem Prototyp), `live.js` (Anbindung), `config.js`
- `tools/bauen.py` – baut `docs/index.html` aus dem Prototyp neu
- `tests/` – Tests der Buchungslogik und Klicktest der App (nur lokal)

## Einrichtung (einmalig)
1. Supabase-Projekt „cloudstudios“, Region Frankfurt (eu-central-1)
2. Database → Extensions: `pg_cron` aktivieren
3. SQL-Editor: erst `01_schema.sql`, dann `02_zeitplan.sql`
4. Authentication → Sign In / Providers: „Allow new users to sign up“ AUS, „Confirm email“ AUS
   Authentication → URL Configuration: Site URL und Redirect auf die GitHub-Pages-Adresse
   SQL-Editor: `03_app_daten.sql`; Edge Functions: `einladen` (Code aus `supabase/functions/einladen/index.ts`)
5. Erster Benutzer (Cem): Authentication → Users → Add user, „Auto Confirm“ an. Danach im SQL-Editor:
   `update profiles set rolle = 'admin' where id = '<ID aus Users>';`
6. Weitere Konten legt Cem in der App an (Mehr → Konten). Die Funktion „einladen“ erzeugt einen persönlichen Link,
   den Cem per WhatsApp schickt. Der Kunde legt darüber sein Passwort fest. Kein E-Mail-Versand nötig.
7. Storage: Bucket `zustand` (privat) für Fotos von Zustandsmeldungen.

## Regeln (in der Datenbank, nicht umgehbar)
- Credits je Stunde: Studio 1 und 3 = 1, Studio 4 = 2, Studio 5 = 4,5
- Mindestens 2 Stunden; Buchung nur mit Deckung, sonst Vorschlag der möglichen Stunden
- Walk-In-Anfrage hält den Slot bis 24 Std. vor Beginn, bei kurzfristigen Buchungen bis zum Beginn
- Credits gehen bei Buchung ab; Storno mehr als 24 Std. vorher → zurück; Mitglieder: 12 Std., später halbe Credits
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
python3 tests/test_buchungslogik.py          # Datenbank (legt cs_test neu an)
python3 tests/web/server.py 8765 &           # App gegen die Test-Datenbank
python3 tests/web/klick.py                   # Klicktest: Admin, Kunde, Partner
```
