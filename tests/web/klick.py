"""Klicktest der Live-App gegen die lokale Test-Datenbank (alle drei Ansichten)."""
import sys, psycopg2
from playwright.sync_api import sync_playwright
db = psycopg2.connect("host=/tmp port=5433 user=postgres dbname=cs_test"); db.autocommit = True
def uid(name): c = db.cursor(); c.execute("select id from profiles where name=%s", (name,)); return c.fetchone()[0]
BASE = 'http://127.0.0.1:8765/test.html?user='
fehler, ok = [], 0
def check(n, b, info=''):
    global ok
    if b: ok += 1; print('  ✓', n)
    else: fehler.append(n); print('  ✗', n, info)

with sync_playwright() as p:
    br = p.chromium.launch(executable_path='/usr/bin/google-chrome', args=['--no-sandbox'])
    def seite(name, w=1200, h=900):
        pg = br.new_page(viewport={'width': w, 'height': h}); errs = []
        pg.on('pageerror', lambda e: errs.append(str(e))); pg.on('dialog', lambda d: d.accept('RN-CS-990'))
        pg.goto(BASE + uid(name)); pg.wait_for_timeout(1500); return pg, errs

    print('Admin')
    pg, errs = seite('Cem')
    txt = pg.inner_text('#app')
    check('Admin-Ansicht lädt ohne Fehler', not errs, errs[:2])
    check('Dashboard sichtbar', 'Dashboard' in txt or 'DASHBOARD' in txt, txt[:200])
    check('Keine Beispielkunden aus dem Prototyp', 'Anna Weber' not in txt)
    pg.screenshot(path='/tmp/w_admin.png', full_page=False)
    for tab in ['kalender', 'eintragen', 'anfragen', 'mehr']:
        b = pg.query_selector(f'[data-itab="{tab}"]')
        if b: b.click(); pg.wait_for_timeout(300)
        check(f'Tab {tab} ohne Fehler', not errs, errs[-1:] if errs else '')
    for m in ['kunden', 'raeume', 'konten', 'zahlen', 'codes', 'abrechnung', 'einstellungen', 'mitteilungen', 'protokoll']:
        b = pg.query_selector(f'[data-mtab="{m}"]')
        if b: b.click(); pg.wait_for_timeout(250)
        check(f'Mehr/{m} ohne Fehler', not errs, errs[-1:] if errs else '')
    pg.query_selector('[data-mtab="abrechnung"]').click(); pg.wait_for_timeout(300)
    check('Abrechnung aus der Datenbank', 'Walk-In' in pg.inner_text('#app') or 'Credit' in pg.inner_text('#app'), pg.inner_text('#app')[-600:])
    pg.screenshot(path='/tmp/w_abrechnung.png')
    # Walk-In eintragen
    pg.query_selector('[data-itab="eintragen"]').click(); pg.wait_for_timeout(300)
    pg.fill('#f-intern input[name=name]', 'Walk-In Test'); pg.fill('#f-intern input[name=preis]', '60')
    pg.select_option('#f-intern select[name=tag]', '12'); pg.select_option('#f-intern select[name=start]', '8')
    pg.click('#f-intern [type=submit]'); pg.wait_for_timeout(1200)
    check('Walk-In eingetragen', 'Eingetragen' in pg.inner_text('#f-intern-msg'), pg.inner_text('#f-intern-msg'))
    c = db.cursor(); c.execute("select count(*) from buchungen where gast_name='Walk-In Test' and preis_brutto=60"); check('…in der Datenbank', c.fetchone()[0] == 1)
    # Zahlung bestätigen
    pg.query_selector('[data-itab="anfragen"]').click(); pg.wait_for_timeout(300)
    z = pg.query_selector('[data-zahlung]')
    if z: z.click(); pg.wait_for_timeout(1200)
    c.execute("select status, rechnung from buchungen where gast_name='Walk-In Test'"); r = c.fetchone()
    check('Zahlung bestätigt mit RN', r == ('gebucht', 'RN-CS-990'), r)
    # Türcode
    pg.query_selector('[data-itab="mehr"]').click(); pg.wait_for_timeout(200); pg.query_selector('[data-mtab="codes"]').click(); pg.wait_for_timeout(300)
    inp = pg.query_selector('[data-code="2"]')
    if inp: inp.fill('9911'); pg.wait_for_timeout(1500)
    c.execute("select code from tuercodes where tag = current_date + 2"); r = c.fetchone()
    check('Türcode gespeichert', r and r[0] == '9911', r)
    check('Admin ohne JS-Fehler', not errs, errs)

    print('Kunde (Anna)')
    pg, errs = seite('Anna', 390, 844)
    txt = pg.inner_text('#app')
    check('Kunden-Ansicht lädt', not errs and ('Guthaben' in txt or 'GUTHABEN' in txt or 'Credits' in txt), (errs[:2], txt[:300]))
    pg.screenshot(path='/tmp/w_kunde.png')
    vorher = db.cursor(); vorher.execute("select count(*) from buchungen where kunde=%s and status='gebucht'", (uid('Anna'),)); n0 = vorher.fetchone()[0]
    pg.query_selector('[data-ktab="buchen"]').click(); pg.wait_for_timeout(400)
    pg.screenshot(path='/tmp/w_kunde_buchen.png')
    kt = pg.query_selector('[data-kftag="6"]')
    if kt: kt.click(); pg.wait_for_timeout(300)
    s = pg.query_selector('select[data-fstart]')
    if s: s.select_option('11'); pg.wait_for_timeout(200)
    kb = pg.query_selector('[data-kbuchen]')
    if kb: kb.click(); pg.wait_for_timeout(1500)
    vorher.execute("select count(*) from buchungen where kunde=%s and status='gebucht'", (uid('Anna'),)); n1 = vorher.fetchone()[0]
    msg = pg.inner_text('#app')[:300]
    check('Kunde bucht mit Credits', n1 == n0 + 1, (n0, n1, msg, pg.inner_text('#k-msg') if pg.query_selector('#k-msg') else ''))
    for tab in ['start', 'shop', 'verlauf', 'konto']:
        b = pg.query_selector(f'[data-ktab="{tab}"]')
        if b: b.click(); pg.wait_for_timeout(300)
        check(f'Kunde Tab {tab}', not errs, errs[-1:] if errs else '')
    check('Kunde sieht keine fremden Namen', 'Walk-In Test' not in pg.content())

    print('Partner')
    for name in ['Andrews', 'Basement1']:
        pg, errs = seite(name, 390, 844)
        check(f'{name}: Ansicht lädt', not errs, errs[:2])
        for b in pg.query_selector_all('[data-ptab]'):
            try: b.click(); pg.wait_for_timeout(250)
            except Exception: pass
        check(f'{name}: alle Tabs ohne Fehler', not errs, errs[-2:])
        check(f'{name}: keine Walk-In-Namen', 'Walk-In Test' not in pg.content())
        pg.screenshot(path=f'/tmp/w_{name}.png')
    br.close()
print(f'\n{ok} bestanden, {len(fehler)} fehlgeschlagen'); sys.exit(1 if fehler else 0)
