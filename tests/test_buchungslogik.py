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
    for f in ("tests/00_supabase_stub.sql", "supabase/01_schema.sql"):
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
check("Andrews sieht nur Studio 4 und 5", studios_pk <= {"s4", "s5"} and studios_pk, str(studios_pk))
check("Kunden sehen Eigennutzung als belegt", A.q("select titel from kalender(%s,%s) where id=%s", t(-1), t(60), pb)[0][0] == "Belegt")
check("Partner darf keine geschlossene Gesellschaft setzen", PB.fehler("select blockieren('s3', %s, %s, 'x', true)", t(12, 8), t(12, 9)) == "KEIN_ZUGRIFF")

print("11. Abrechnung")
monat = t(7, 12).date().replace(day=1)
ab = {(p, x): float(b) for p, x, m, b in C.q("select * from partner_abrechnung(%s)", monat)}
print("    ", ab)
check("Andrews sieht seine Abrechnung", PK.fehler("select * from partner_abrechnung(%s)", monat) is None)
check("Andrews sieht keine Basement-Zeilen", all(r[0] == "blackclouds" for r in PK.q("select * from partner_abrechnung(%s)", monat)))
check("Kunde sieht keine Abrechnung", A.fehler("select * from partner_abrechnung(%s)", monat) == "KEIN_ZUGRIFF")
check("Basement-Pauschale: 50 % netto = 126,05 €", ab.get(("basement", "Basement-Pauschalen (50 % netto)")) == 126.05)

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
konto_summe = {u: float(su("select coalesce(sum(credits),0) from bewegungen where kunde=%s", u)[0][0]) for u in (anna, ben, lea, mia, nina, olga)}
check("Für alle Kunden: Bewegungen = Kontostand", all(abs(konto_summe[u] - stand(C, u)) < 0.001 for u in konto_summe), str(konto_summe))

print(f"\n{ok} bestanden, {len(fails)} fehlgeschlagen")
if fails: print("Fehlgeschlagen:", *fails, sep="\n  - "); sys.exit(1)
