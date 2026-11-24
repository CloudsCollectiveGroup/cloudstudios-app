-- CloudStudios Studio-App · 02_zeitplan.sql
-- Automatische Läufe. Vorher in Supabase: Database → Extensions → "pg_cron" aktivieren.
-- Zeiten in UTC (Hamburg = UTC+1 im Winter, UTC+2 im Sommer).
select cron.schedule('anfragen-freigeben', '*/15 * * * *', $$select public.anfragen_verfallen_lassen()$$);
select cron.schedule('credits-verfall',   '15 23 * * *',  $$select public.verfall_buchen()$$);           -- täglich ca. 00:15 Uhr
select cron.schedule('mitglieder-monat',  '5 23,0 28-31,1 * *', $$select public.mitglieder_monatslauf()$$); -- läuft um Mitternacht zum Monatsersten; doppelt ist ausgeschlossen
