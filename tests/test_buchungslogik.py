"""Automatische Tests der Buchungslogik (Phase 1).
Läuft gegen eine lokale Postgres-Datenbank mit tests/00_supabase_stub.sql + supabase/01_schema.sql.
Aufruf: python3 tests/test_buchungslogik.py
"""
import subprocess, sys, threading, uuid, datetime as dt
import psycopg2

DSN = "host=/tmp port=5433 user=postgres"
DB = "cs_test"
ROOT = __file__.rsplit("/tests/", 1)[0]

def sh(cmd):
    subprocess.run(cmd, shell=True, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

def frische_db():
    sh(f'psql -h /tmp -p 5433 -U postgres -q -c "drop database if exists {DB}" -c "create database {DB}"')
    for f in ("tests/00_supabase_stub.sql", "supabase/01_schema.sql", "supabase/03_app_daten.sql"):
        sh(f"psql -h /tmp -p 5433 -U postgres -q -v ON_ERROR_STOP=1 -d {DB} -f {ROOT}/{f}")

frische_db()
admin = psycopg2.connect(DSN + f" dbname={DB}"); admin.autocommit = True

def su(sql, *a):
    with admin.cursor() as c:
        c.execute(sql, a)
        return c.fetchall() if c.description else None

def benutzer(name, rolle="kunde", partner=None, kn=None):
    uid = str(uuid.uuid4())
    su("insert into auth.users(id,email,raw_user_meta_data) values (%s,%s,%s)", uid, f"{name}@test.de",
       '{"name":"%s"}' % name)
    su("update profiles set rolle=%s, partner=%s, kn=%s where id=%s", rolle, partner, kn, uid)
    return uid

class Als:
    """Verbindung als angemeldeter Benutzer (Rolle authenticated, wie in Supabase)."""
    def __init__(self, uid):
        self.c = psycopg2.connect(DSN + f" dbname={DB}"); self.c.autocommit = True
        with self.c.cursor() as k:
            k.execute("set role authenticated"); k.execute("select set_config('request.jwt.claim.sub', %s, false)", (uid,))
    def q(self, sql, *a):
        with self.c.cursor() as k:
            k.execute(sql, a)
            return k.fetchall() if k.description else None
    def fehler(self, sql, *a):
        try:
            self.q(sql, *a); return None
        except psycopg2.Error as e:
            return (e.pgerror or str(e)).split("\n")[0].replace("ERROR:  ", "")

ok = 0; fails = []
def check(name, bedingung, info=""):
    global ok
    if bedingung: ok += 1; print("  ✓", name)
    else: fails.append(name); print("  ✗", name, info)

jetzt = dt.datetime.now(dt.timezone.utc).replace(minute=0, second=0, microsecond=0)
def t(tage=0, std=0): return jetzt + dt.timedelta(days=tage, hours=std)

cem   = benutzer("Cem", "admin")
team  = benutzer("Team", "team")
anna  = benutzer("Anna", kn="KN-101")
ben   = benutzer("Ben", kn="KN-102")
lea   = benutzer("Lea", kn="KN-103")
mia   = benutzer("Mia", kn="KN-104")
base  = benutzer("Basement1", "partner", "basement")
black = benutzer("Andrews", "partner", "blackclouds")
A, B, L, M, T, C, PB, PK = (Als(x) for x in (anna, ben, lea, mia, team, cem, base, black))

def stand(k, kunde=None):
    r = (k.q("select verfuegbar from konto(%s)", kunde) if kunde else k.q("select verfuegbar from konto()"))[0][0]
    return float(r)

print("1. Aufladen und Selbstbuchung")
check("Kunde darf nicht selbst aufladen", A.fehler("select credits_aufladen(%s,'paket',20,'RN-1')", anna) == "KEIN_ZUGRIFF")
check("Team ohne Recht 'aufladen' darf nicht aufladen", T.fehler("select credits_aufladen(%s,'paket',20,'RN-CS-1')", anna) == "KEIN_ZUGRIFF")
check("Nur Admin schaltet Rechte", T.fehler("select recht_setzen('buchung','aufladen',true)") == "KEIN_ZUGRIFF")
C.q("select recht_setzen('buchung','aufladen',true)")
check("Nach Freischaltung darf Team aufladen", T.q("select darf('aufladen')")[0][0] is True)
check("Paket ohne Rechnungsnummer abgelehnt", T.fehler("select credits_aufladen(%s,'paket',20)", anna) == "RECHNUNG_FEHLT")
T.q("select credits_aufladen(%s,'paket',20,'RN-CS-900')", anna)
check("Anna hat 20 Credits", stand(A) == 20)
gueltig = A.q("select gueltig_bis from credit_posten where kunde=%s", anna)[0][0]
heute = dt.datetime.now(dt.timezone(dt.timedelta(hours=1))).date()
check("Paket gültig 3 Monate ab Zahlungseingang", (gueltig - heute).days in range(88, 93), str(gueltig))
b1 = A.q("select credits_buchen('s1', %s, 4)", t(3, 10))[0][0]
check("Studio 1, 4 Std. → 16 Credits übrig", stand(A) == 16)
check("Reserviert zeigt 4", float(A.q("select reserviert from konto()")[0][0]) == 4)

print("2. Regeln")
T.q("select credits_aufladen(%s,'paket',3,'RN-CS-901')", ben)
check("3 Credits, 4 Std. → Vorschlag 3 Std.", B.fehler("select credits_buchen('s1', %s, 4)", t(4, 10)) == "ZU_WENIG_CREDITS:3")
check("max_stunden liefert 3", float(B.q("select max_stunden('s1', %s)", t(4, 10))[0][0]) == 3)
check("1 Std. abgelehnt (Mindestbuchung)", A.fehler("select credits_buchen('s1', %s, 1)", t(5, 10)) == "MINDESTENS_2_STUNDEN")
check("Vergangenheit abgelehnt", A.fehler("select credits_buchen('s1', %s, 2)", t(-1)) == "VERGANGENHEIT")
check("Studio 5 für Kunden nur auf Anfrage", A.fehler("select credits_buchen('s5', %s, 2)", t(5, 10)) == "NUR_AUF_ANFRAGE")
check("Kunde kann nicht für andere buchen", A.fehler("select credits_buchen('s1', %s, 2, %s)", t(5, 10), ben) == "KEIN_ZUGRIFF")
T.q("select credits_buchen('s5', %s, 2, %s, 'Freigabe Andrews')", t(6, 12), anna)
check("Team bucht Studio 5 für Anna: 2 Std. × 4,5 = 9 → 7 übrig", stand(A) == 7)
A.q("select credits_buchen('s4', %s, 2)", t(7, 12))
check("Studio 4: 2 Std. × 2 = 4 → 3 übrig", stand(A) == 3)

print("3. Doppelbuchung")
T.q("select credits_aufladen(%s,'paket',20,'RN-CS-902')", lea)
check("Überschneidender Slot abgelehnt", L.fehler("select credits_buchen('s1', %s, 3)", t(3, 12)) == "SLOT_BELEGT")
check("Bei Ablehnung nichts abgezogen", stand(L) == 20)
L.q("select credits_buchen('s1', %s, 2)", t(3, 14))
check("Direkt anschließender Slot (14 Uhr) erlaubt", stand(L) == 18)
check("Anderes Studio zur selben Zeit erlaubt", L.fehler("select credits_buchen('s3', %s, 2)", t(3, 10)) is None)

print("4. Gleichzeitige Buchungen (zwei Klicks in derselben Sekunde)")
T.q("select credits_aufladen(%s,'paket',4,'RN-CS-903')", mia)
erg = []
def klick(stunde):
    k = Als(mia); erg.append(k.fehler("select credits_buchen('s1', %s, 4)", t(10, stunde)))
th = [threading.Thread(target=klick, args=(h,)) for h in (8, 14)]
[x.start() for x in th]; [x.join() for x in th]
check("Gleiches Guthaben nur einmal verwendet", sorted(map(str, erg)) == ["None", "ZU_WENIG_CREDITS:0"], str(erg))
check("Mia hat 0", stand(M) == 0)
erg = []
def klick2(k): erg.append(k.fehler("select credits_buchen('s3', %s, 2)", t(11, 10)))
th = [threading.Thread(target=klick2, args=(Als(u),)) for u in (anna, lea)]
[x.start() for x in th]; [x.join() for x in th]
check("Gleicher Slot, zwei Kunden: nur einer kommt durch", sorted(map(str, erg)) == ["None", "SLOT_BELEGT"], str(erg))

print("5. Storno")
s_spaet = L.q("select credits_buchen('s1', %s, 2)", t(0, 10))[0][0]
vorher = stand(L)
check("Storno unter 24 Std.: Credits bleiben weg", L.q("select stornieren(%s)", s_spaet)[0][0] == "NICHT_ERSTATTET" and stand(L) == vorher)
vorher = stand(A)
check("Storno über 24 Std.: Credits zurück", A.q("select stornieren(%s)", b1)[0][0] == "ERSTATTET" and stand(A) == vorher + 4)
check("Slot nach Storno wieder frei", L.fehler("select credits_buchen('s1', %s, 2)", t(3, 10)) is None)
check("Fremde Buchung nicht stornierbar", B.fehler("select stornieren(%s)", s_spaet) == "KEIN_ZUGRIFF")
check("Kulanz nur für Admin", T.fehler("select stornieren(%s, true)", s_spaet) in ("NICHT_STORNIERBAR", "KEIN_ZUGRIFF"))

print("6. Älteste Credits zuerst, Gültigkeit, Einschränkungen")
nina = benutzer("Nina", kn="KN-105"); N = Als(nina)
su("""insert into credit_posten(kunde,art,credits,gueltig_ab,gueltig_bis) values
      (%s,'paket',5,current_date - 80, current_date + 10), (%s,'paket',10,current_date, current_date + 90)""", nina, nina)
su("insert into bewegungen(kunde,art,credits,posten) select kunde,'kauf',credits,id from credit_posten where kunde=%s", nina)
bn = N.q("select credits_buchen('s1', %s, 6)", t(2, 9))[0][0]
z = su("select p.credits, z.credits from zuordnungen z join credit_posten p on p.id=z.posten where z.buchung=%s order by p.gueltig_bis", bn)
check("Erst der ältere Posten (5), dann 1 aus dem neuen", [(float(a), float(b)) for a, b in z] == [(5, 5), (10, 1)], str(z))
check("Termin nach Ablauf: nur Credits, die dann noch gelten (9)", N.fehler("select credits_buchen('s1', %s, 10)", t(20, 9)) == "ZU_WENIG_CREDITS:9")
T.q("select credits_aufladen(%s,'label',20)", ben)
check("Label-Credits nicht in Studio 3", B.fehler("select credits_buchen('s3', %s, 4)", t(5, 10)) == "ZU_WENIG_CREDITS:3")
check("Label-Credits in Studio 1 nutzbar", B.fehler("select credits_buchen('s1', %s, 4)", t(1, 9)) is None)

print("7. Verfall")
su("insert into credit_posten(kunde,art,credits,gueltig_ab,gueltig_bis) values (%s,'paket',7,current_date-100,current_date-5)", nina)
su("insert into bewegungen(kunde,art,credits,posten) select kunde,'kauf',credits,id from credit_posten where kunde=%s and credits=7", nina)
vorher = stand(N)
n1 = C.q("select verfall_buchen()")[0][0]; n2 = C.q("select verfall_buchen()")[0][0]
check("Abgelaufener Rest verfällt einmal", n1 >= 1 and n2 == 0)
check("Kontostand zählt Abgelaufenes nicht", stand(N) == vorher)
summe = float(su("select sum(credits) from bewegungen where kunde=%s", nina)[0][0] or 0)
check("Bewegungen summieren sich zum Kontostand", summe == stand(N) + 0, f"{summe} vs {stand(N)}")

print("8. Mitglieder-Monatslauf")
olga = benutzer("Olga", kn="KN-106"); O = Als(olga)
su("insert into mitgliedschaften(kunde,tarif,credits_monat,beitrag_brutto,aktiv_ab) values (%s,'PA 202 M',30,0,current_date-40)", olga)
su("insert into mitgliedschaften(kunde,tarif,credits_monat,nur_studios,beitrag_brutto,basement_pauschale,aktiv_ab) values (%s,'Basement 40',40,'{s3}',300,true,current_date-40)", ben)
check("Monatslauf bucht 2 Monatsguthaben", C.q("select mitglieder_monatslauf()")[0][0] == 2)
check("Zweiter Lauf bucht nichts doppelt", C.q("select mitglieder_monatslauf()")[0][0] == 0)
check("Olga hat 30", stand(O) == 30)
ende = su("select gueltig_bis from credit_posten where kunde=%s", olga)[0][0]
check("Mitglieder-Credits gelten bis Monatsende", ende.month != (ende + dt.timedelta(days=1)).month)
tag = max(1, min(3, (ende - heute).days))
bo = O.q("select credits_buchen('s1', %s, 2)", t(0, 26) if (ende - heute).days >= 2 else t(0, 3))[0][0]
farbe = O.q("select farbe from kalender(%s,%s) where id=%s", t(-1), t(60), bo)[0][0]
check("Mitglieder-Termin ist lila", farbe == "lila", farbe)
check("Kunden-Termin ist blau", A.q("select farbe from kalender(%s,%s) where eigene limit 1", t(-1), t(60))[0][0] == "blau")
check("Basement-Credits nur Studio 3", B.fehler("select credits_buchen('s4', %s, 2)", t(8, 10)) is not None)

print("9. Team-Cockpit: Walk-In, Blockieren")
w = T.q("select anfrage_eintragen('s1', %s, 4, 'Walk-In Max', null, null, 60, 'AN-CS-500')", t(4, 18))[0][0]
check("Kunde darf keine Anfrage eintragen", A.fehler("select anfrage_eintragen('s1', %s, 4, 'X')", t(4, 9)) == "KEIN_ZUGRIFF")
check("Anfrage ist grün", T.q("select farbe from kalender(%s,%s) where id=%s", t(-1), t(60), w)[0][0] == "gruen")
titel = A.q("select titel, status from kalender(%s,%s) where id=%s", t(-1), t(60), w)[0]
check("Kunde sieht nur 'Belegt' ohne Namen", titel == ("Belegt", "belegt"), str(titel))
check("Angefragter Slot blockiert Buchung", L.fehler("select credits_buchen('s1', %s, 2)", t(4, 19)) == "SLOT_BELEGT")
T.q("select zahlung_bestaetigen(%s, 'RN-CS-950')", w)
check("Nach Zahlung blau", T.q("select farbe from kalender(%s,%s) where id=%s", t(-1), t(60), w)[0][0] == "blau")
w2 = T.q("select anfrage_eintragen('s1', %s, 4, 'Walk-In Abgelaufen')", t(6, 8))[0][0]
su("update buchungen set reserviert_bis = now() - interval '1 minute' where id=%s", w2)
check("Abgelaufene Anfrage gibt Slot frei", L.fehler("select credits_buchen('s1', %s, 2)", t(6, 9)) is None)
check("…und steht auf verfallen", su("select status from buchungen where id=%s", w2)[0][0] == "verfallen")
g = T.q("select blockieren('s1', %s, %s, 'Release Party', true)", t(9, 18), t(9, 23))[0][0]
check("Geschlossene Gesellschaft ist rot", T.q("select farbe from kalender(%s,%s) where id=%s", t(-1), t(60), g)[0][0] == "rot")

print("10. Partner")
pb = PB.q("select blockieren('s3', %s, %s, 'Eigennutzung')", t(5, 18), t(5, 22))[0][0]
check("Basement blockiert Studio 3 (grau)", PB.q("select farbe from kalender(%s,%s) where id=%s", t(-1), t(60), pb)[0][0] == "grau")
check("Basement darf Studio 1 nicht blockieren", PB.fehler("select blockieren('s1', %s, %s, 'x')", t(5, 8), t(5, 9)) == "KEIN_ZUGRIFF")
check("Andrews darf Studio 3 nicht blockieren", PK.fehler("select blockieren('s3', %s, %s, 'x')", t(5, 8), t(5, 9)) == "KEIN_ZUGRIFF")
studios_pk = {r[0] for r in PK.q("select studio from kalender(%s,%s)", t(-1), t(60))}
check("Andrews sieht eigene Studios plus Studio 1/Lounge, nie Studio 3", "s3" not in studios_pk and {"s4", "s5"} & studios_pk and studios_pk <= {"s1", "s4", "s5", "lounge"}, str(studios_pk))
check("Kunden sehen Eigennutzung als belegt", A.q("select titel from kalender(%s,%s) where id=%s", t(-1), t(60), pb)[0][0] == "Belegt")
check("Partner darf keine geschlossene Gesellschaft setzen", PB.fehler("select blockieren('s3', %s, %s, 'x', true)", t(12, 8), t(12, 9)) == "KEIN_ZUGRIFF")

print("11. Abrechnung")
monat = t(7, 12).date().replace(day=1)
ab = {(p, x): float(b) for p, x, m, b in C.q("select * from partner_abrechnung(%s)", monat)}
print("    ", ab)
check("Andrews sieht seine Abrechnung", PK.fehler("select * from partner_abrechnung(%s)", monat) is None)
check("Andrews sieht keine Basement-Zeilen", all(r[0] == "blackclouds" for r in PK.q("select * from partner_abrechnung(%s)", monat)))
check("Kunde sieht keine Abrechnung", A.fehler("select * from partner_abrechnung(%s)", monat) == "KEIN_ZUGRIFF")
check("Basement-Pauschalen bringen keinen Anteil mehr (seit 25.11.)", ("basement", "Basement-Pauschalen (50 % netto)") not in ab)

print("13. Tarife, Partner-Obergrenze (PA 220)")
# Zwei Tage im selben Monat finden (Monatswechsel umgehen)
d1 = next(d for d in range(1, 10) if t(d).astimezone(dt.timezone(dt.timedelta(hours=1))).month == t(d + 1).astimezone(dt.timezone(dt.timedelta(hours=1))).month)
monat = t(d1).astimezone(dt.timezone(dt.timedelta(hours=1))).date().replace(day=1)
vic = benutzer("Vic", kn="KN-115"); V = Als(vic)
check("Team ohne Recht 'konten' legt keine Mitgliedschaft an", T.fehler("select mitgliedschaft_anlegen(%s,'PA 220',%s)", vic, monat) == "KEIN_ZUGRIFF")
C.q("select mitgliedschaft_anlegen(%s,'PA 220',%s,'VN-035')", vic, monat)
C.q("select mitglieder_monatslauf(%s)", monat)
check("PA 220: 60 Credits im Monat", float(su("select coalesce(sum(credits),0) from credit_posten where kunde=%s", vic)[0][0]) == 60)
check("Studio 4: 10 Std. = 20 Credits erlaubt", V.fehler("select credits_buchen('s4', %s, 10)", t(d1, 1)) is None)
check("Über 30 Credits in Partnerstudios abgelehnt", V.fehler("select credits_buchen('s4', %s, 6)", t(d1 + 1, 2)) == "PARTNER_GRENZE:10")
check("Bis zur Grenze erlaubt (4 Std. = 8)", V.fehler("select credits_buchen('s4', %s, 4)", t(d1 + 1, 2)) is None)
_e = V.fehler("select credits_buchen('s1', %s, 4)", t(d1 + 1, 19)); check("Studio 1 zählt nicht zur Grenze", _e is None, str(_e))
check("Team ohne Recht ändert keine Tarife", T.fehler("select tarif_speichern('Basement 20','Basement 20','basement',20,160,array['s3'])") == "KEIN_ZUGRIFF")
C.q("select tarif_speichern('Basement 20','Basement 20','basement',20,160,array['s3'])")
check("Admin legt neue Basement-Pauschale an", su("select credits_monat from tarife where id='Basement 20'")[0][0] == 20)

print("14. Studio 5: Bewerbung, Prüfliste, Freigabeliste")
kiro = benutzer("Kiro", kn="KN-116"); K = Als(kiro)
T.q("select credits_aufladen(%s,'paket',30,'RN-CS-960')", kiro)
check("Bewerbung ohne Regeln abgelehnt", K.fehler("select bewerbung_senden(%s,4,'Kiro','spotify/kiro',3,2,'Clouds Records','Album',true,false)", t(d1, 14)) == "REGELN_NICHT_AKZEPTIERT")
bw = K.q("select bewerbung_senden(%s,4,'Kiro','spotify/kiro',3,2,'Clouds Records','Album',true,true)", t(d1, 14))[0][0]
check("Basement darf nicht über Studio 5 entscheiden", PB.fehler("select bewerbung_entscheiden(%s,true)", bw) == "KEIN_ZUGRIFF")
pl = PK.q("select kriterium, erfuellt from bewerbung_pruefliste(%s)", bw)
check("Prüfliste für Andrews: 5 Kriterien, alle erfüllt", len(pl) == 5 and all(r[1] for r in pl), str(pl))
check("Andrews sieht die Bewerbung", PK.q("select count(*) from bewerbungen")[0][0] == 1)
check("Basement sieht keine Bewerbungen", PB.q("select count(*) from bewerbungen")[0][0] == 0)
PK.q("select bewerbung_entscheiden(%s,true,true)", bw)
check("Zusage + dauerhaft: Kunde auf Freigabeliste", su("select count(*) from freigaben where kunde=%s and studio='s5'", kiro)[0][0] == 1)
check("Nicht doppelt entscheiden", PK.fehler("select bewerbung_entscheiden(%s,false)", bw) == "SCHON_ENTSCHIEDEN")
k5 = K.q("select credits_buchen('s5', %s, 2)", t(d1, 14))[0][0]
check("Freigegebener Kunde bucht Studio 5 selbst (9 Credits)", float(su("select credits from buchungen where id=%s", k5)[0][0]) == 9)
PK.q("select freigabe_setzen(%s,false)", kiro)
check("Nach Entzug wieder nur auf Anfrage", K.fehler("select credits_buchen('s5', %s, 2)", t(d1 + 1, 18)) == "NUR_AUF_ANFRAGE")
check("Basement darf Studio-5-Freigabe nicht setzen", PB.fehler("select freigabe_setzen(%s,true)", kiro) == "KEIN_ZUGRIFF")
T.q("select nicht_erschienen_setzen(%s,true)", k5)
pl = dict(PK.q("select kriterium, erfuellt from bewerbung_pruefliste(%s)", bw))
check("Nicht erschienen fließt in die Prüfliste", pl.get("Keine nicht wahrgenommenen Termine") is False)
T.q("select nicht_erschienen_setzen(%s,false)", k5)

print("15. Veranstaltung: Lounge + Studio 1")
g2 = T.q("select veranstaltung_eintragen(%s,%s,'Release Party KN-104')", t(15, 18), t(15, 23))[0][0]
check("Lounge und Studio 1 gemeinsam gesperrt", su("select count(*) from buchungen where gruppe=%s and status='geschlossen'", g2)[0][0] == 2)
check("Studio 1 während Veranstaltung belegt", A.fehler("select credits_buchen('s1', %s, 2)", t(15, 19)) == "SLOT_BELEGT")
check("Lounge nie mit Credits", A.fehler("select credits_buchen('lounge', %s, 2)", t(16, 10)) == "NUR_VERANSTALTUNG")
check("Zweite Veranstaltung zur selben Zeit abgelehnt", T.fehler("select veranstaltung_eintragen(%s,%s,'x')", t(15, 20), t(15, 22)) == "SLOT_BELEGT")
pk = {r[0]: r[1] for r in PK.q("select studio, titel from kalender(%s,%s)", t(15), t(16))}
check("Partner sieht Studio 1 und Lounge als Veranstaltung", pk.get("lounge") == "Veranstaltung" and pk.get("s1") == "Veranstaltung", str(pk))
eine = su("select id from buchungen where gruppe=%s limit 1", g2)[0][0]
T.q("select stornieren(%s)", eine)
check("Storno gibt beide Räume frei", su("select count(*) from buchungen where gruppe=%s and status='storniert'", g2)[0][0] == 2)

print("16. Zustand, Mitteilungen, Gutschrift")
su("insert into buchungen(studio,zeitraum,status,kunde,credits) values ('s3', tstzrange(now()-interval '5 hours', now()-interval '2 hours'), 'gebucht', %s, 0)", ben)
letzte = su("select max(id) from buchungen where studio='s3' and upper(zeitraum) < now()")[0][0]
check("Basement meldet nicht für Studio 4", PB.fehler("select zustand_melden('s4','Kabel kaputt')") == "KEIN_ZUGRIFF")
zm = PB.q("select zustand_melden('s3','Kopfhörerkabel gerissen')")[0][0]
check("Meldung hängt an der letzten Buchung", su("select buchung from zustandsmeldungen where id=%s", zm)[0][0] == letzte)
check("Gemeinschaftsflächen darf jeder Partner melden", PK.fehler("select zustand_melden('gemein','Küche nicht aufgeräumt')") is None)
check("Andrews sieht nur eigene Meldungen", PK.q("select count(*) from zustandsmeldungen")[0][0] == 1)
check("Kunde sieht keine Meldungen", A.q("select count(*) from zustandsmeldungen")[0][0] == 0)
T.q("select zustand_erledigt(%s)", zm)
check("Team erledigt Meldung", su("select status from zustandsmeldungen where id=%s", zm)[0][0] == "erledigt")
check("Partner schreibt nicht an anderen Partner", PB.fehler("select mitteilung_senden('blackclouds','hallo')") == "KEIN_ZUGRIFF")
PB.q("select mitteilung_senden('basement','Bitte Rauchmelder prüfen')"); T.q("select mitteilung_senden('basement','Erledigt')")
check("Basement sieht beide Mitteilungen", PB.q("select count(*) from mitteilungen")[0][0] == 2)
check("Andrews sieht sie nicht", PK.q("select count(*) from mitteilungen")[0][0] == 0)
PB.q("select gutschrift_bestaetigen(current_date)")
check("Gutschrift bestätigt (Admin sieht es)", C.q("select count(*) from gutschrift_bestaetigungen where partner='basement'")[0][0] == 1)
check("Andrews sieht fremde Bestätigung nicht", PK.q("select count(*) from gutschrift_bestaetigungen")[0][0] == 0)
check("Team kann keine Gutschrift bestätigen", T.fehler("select gutschrift_bestaetigen(current_date)") == "KEIN_ZUGRIFF")

print("17. Konto sperren")
check("Team ohne Recht 'konten' sperrt nicht", T.fehler("select profil_setzen(%s, p_aktiv => false)", kiro) == "KEIN_ZUGRIFF")
C.q("select profil_setzen(%s, p_aktiv => false)", kiro)
check("Gesperrter Kunde kann nicht buchen", K.fehler("select credits_buchen('s1', %s, 2)", t(17, 10)) == "NICHT_ANGEMELDET")
check("Team bucht nicht für gesperrtes Konto", T.fehler("select credits_buchen('s1', %s, 2, %s)", t(17, 10), kiro) == "KONTO_GESPERRT")
C.q("select profil_setzen(%s, p_aktiv => true)", kiro)
check("Nach Entsperren wieder buchbar", K.fehler("select credits_buchen('s1', %s, 2)", t(17, 10)) is None)

print("12. Sicherheit")
check("Kunde kann nicht direkt in Tabellen schreiben", A.fehler("insert into credit_posten(kunde,art,credits,gueltig_ab,gueltig_bis) values (%s,'paket',999,current_date,current_date+90)", anna) is not None)
check("Kunde kann Buchung nicht direkt ändern", A.fehler("update buchungen set credits = 0") is not None)
check("Kunde sieht nur eigene Buchungen", {r[0] for r in A.q("select kunde::text from buchungen")} == {anna})
check("Kunde sieht nur eigene Bewegungen", {r[0] for r in A.q("select kunde::text from bewegungen")} == {anna})
check("Kunde sieht kein Protokoll", A.q("select count(*) from protokoll")[0][0] == 0)
check("Interne Funktion nicht aufrufbar", A.fehler("select posten_rest(1)") is not None)
check("Team darf nicht korrigieren", T.fehler("select korrektur(%s, 5, 'Test')", anna) == "KEIN_ZUGRIFF")
vorher = stand(A, None)
C.q("select korrektur(%s, 2, 'Kulanz Technikproblem')", anna)
check("Admin-Korrektur +2", stand(A) == vorher + 2)
C.q("select korrektur(%s, -1, 'Fehlbuchung')", anna)
check("Admin-Korrektur −1", stand(A) == vorher + 1)
check("Korrektur ohne Begründung abgelehnt", C.fehler("select korrektur(%s, 1, '')", anna) == "BEGRUENDUNG_FEHLT")
check("Team darf keine Rollen vergeben", T.fehler("select profil_setzen(%s, null, null, 'admin')", anna) == "KEIN_ZUGRIFF")
check("Jede Aktion protokolliert", C.q("select count(*) from protokoll")[0][0] > 20)
konto_summe = {u: float(su("select coalesce(sum(credits),0) from bewegungen where kunde=%s", u)[0][0]) for u in (anna, ben, lea, mia, nina, olga, vic, kiro)}
check("Für alle Kunden: Bewegungen = Kontostand", all(abs(konto_summe[u] - stand(C, u)) < 0.001 for u in konto_summe), str(konto_summe))

print("18. Stand 25.11.: Mitglieder-Storno, Walk-In BlackClouds, Bonus, PA 230 entfällt")
tz = dt.timezone(dt.timedelta(hours=1))
vorher = stand(O)
bm = O.q("select credits_buchen('s1', %s, 2)", t(0, 5))[0][0]
cr = float(su("select credits from buchungen where id=%s", bm)[0][0])
check("Mitglied: Storno unter 12 Std. = halbe Credits", O.q("select stornieren(%s)", bm)[0][0] == "HALB_ERSTATTET" and abs(stand(O) - (vorher - cr / 2)) < 0.001, f"{stand(O)} vs {vorher - cr/2}")
bm2 = O.q("select credits_buchen('s1', %s, 2)", t(0, 14))[0][0]
vorher = stand(O)
check("Mitglied: Storno über 12 Std. = voll zurück", O.q("select stornieren(%s)", bm2)[0][0] == "ERSTATTET" and stand(O) > vorher)
wd = t(21, 11); wm = wd.astimezone(tz).date().replace(day=1)
vor = {x: float(b) for p_, x, m, b in C.q("select * from partner_abrechnung(%s)", wm) if p_ == "blackclouds"}
wb = T.q("select anfrage_eintragen('s4', %s, 2, 'Walk-In Andrews', null, null, 80, 'AN-CS-501')", wd)[0][0]
T.q("select zahlung_bestaetigen(%s, 'RN-CS-951')", wb)
nach = {x: float(b) for p_, x, m, b in C.q("select * from partner_abrechnung(%s)", wm) if p_ == "blackclouds"}
wk = [x for x in nach if x.endswith("Walk-In (70 % brutto)")]
check("Walk-In Studio 4: Andrews bekommt 70 % von 80 € = 56 €", wk and round(nach[wk[0]] - vor.get(wk[0], 0), 2) == 56.0, str(nach))
bon = benutzer("Bonni", kn="KN-118"); BO = Als(bon)
C.q("select credits_aufladen(%s,'bonus',4)", bon)
bd = t(22, 10); bmo = bd.astimezone(tz).date().replace(day=1)
summe_b = lambda: sum(float(b) for p_, x, m, b in C.q("select * from partner_abrechnung(%s)", bmo) if p_ == "basement")
v = summe_b()
check("Bonus-Credits in Studio 3 buchbar", BO.fehler("select credits_buchen('s3', %s, 2)", bd) is None)
check("Bonus in Studio 3: keine Vergütung an Basement", abs(summe_b() - v) < 0.001, f"{v} → {summe_b()}")
check("Bonus-Credits nicht in Studio 4", BO.fehler("select credits_buchen('s4', %s, 1)", t(22, 15)) is not None)
check("PA 230 nicht mehr aktiv (Basement verwaltet eigene Pauschalen)", su("select count(*) from tarife where id='PA 230' and aktiv")[0][0] == 0)
check("Olga: Bewegungen = Kontostand nach Halb-Storno", abs(float(su("select coalesce(sum(credits),0) from bewegungen where kunde=%s", olga)[0][0]) - stand(C, olga)) < 0.001)
check("PA 201 kostet 267,75 € brutto", float(su("select beitrag_brutto from tarife where id='PA 201'")[0][0]) == 267.75)

print("19. App-Daten (eine Abfrage pro Ansicht)")
import json as _j
def ad(k): r = k.q("select app_daten()")[0][0]; return r if isinstance(r, dict) else _j.loads(r)
da = ad(A); dc = ad(C); dp = ad(PB); dk = ad(PK)
check("Kunde sieht nur sich als Kunde", [k["id"] for k in da["kunden"]] == [anna])
check("Kunde sieht nur eigene Posten", all(p["kunde"] == anna for p in da["posten"]) and len(da["posten"]) > 0)
fremd = [b for b in da["buchungen"] if not b["eigen"]]
check("Fremde Buchungen ohne Kunde und Namen", all(b["kunde"] is None and b["grund"] in ("Belegt", "Veranstaltung") for b in fremd), str(fremd[:2]))
check("Kunde bekommt kein Protokoll, keine Konten", "protokoll" not in da and "konten" not in da)
check("Admin sieht alle Kunden und Konten", len(dc["kunden"]) >= 8 and "konten" in dc and "protokoll" in dc)
check("Admin sieht Namen in Buchungen", any(b.get("gast") for b in dc["buchungen"]))
check("Posten-Rest stimmt mit Kontostand", abs(sum(float(p["rest"]) for p in da["posten"] if p["bis"] >= str(heute)) - stand(A)) < 0.01)
check("Basement sieht eigene Mitteilungen, nicht BlackClouds", all(m["partner"] == "basement" for m in dp["mitteilungen"]))
check("Basement sieht Pauschalen-Kunden ohne Telefon", all(k["tel"] is None for k in dp["kunden"]) and ben in [k["id"] for k in dp["kunden"]])
check("Andrews sieht Bewerbungen", "bewerbungen" in dk and isinstance(dk["bewerbungen"], list))
check("Team hat eigene Rechteliste", "meine_rechte" in ad(T) and "eintragen" in ad(T)["meine_rechte"])
check("Anfrage-Status nur mit Recht", A.fehler("select anfrage_status(1,'erledigt')") == "KEIN_ZUGRIFF")

A.q("select anfrage_neu('paket','Paket 20 angefragt','{\"menge\":20}')")
check("Paket-Anfrage mit Daten", ad(C)["anfragen"][0]["daten"] == {"menge": 20})
check("Kunde setzt keinen Türcode", A.fehler("select tuercode_setzen(current_date,'1234')") == "KEIN_ZUGRIFF")
C.q("select tuercode_setzen(current_date + 1,'4711')"); C.q("select tuercode_setzen(current_date + 9,'0815')")
check("Team sieht Türcodes", len(ad(C)["codes"]) == 2)
check("Kunde ohne Buchung am Tag sieht keinen Code", ad(B)["codes"] == {} or all(v != "0815" for v in ad(B)["codes"].values()))

print(f"\n{ok} bestanden, {len(fails)} fehlgeschlagen")
if fails: print("Fehlgeschlagen:", *fails, sep="\n  - "); sys.exit(1)
