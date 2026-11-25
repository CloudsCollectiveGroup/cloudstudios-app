"""Baut web/index.html aus dem Prototyp: gleiche Oberfläche, Daten aus Supabase (live.js)."""
import sys, pathlib
ROOT = pathlib.Path(__file__).resolve().parent.parent
src = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else '/home/claude/prototyp/index.html').read_text()

def ersetze(alt, neu, n=1):
    global src
    if src.count(alt) != n:
        sys.exit(f'Stelle nicht eindeutig ({src.count(alt)}x): {alt[:80]}')
    src = src.replace(alt, neu)

ersetze('<title>CloudStudios App · Prototyp</title>',
        '<title>CloudStudios</title>\n<meta name="theme-color" content="#07070A">\n<link rel="manifest" href="manifest.json">\n<link rel="apple-touch-icon" href="bilder/icon-192.png">\n<meta name="apple-mobile-web-app-capable" content="yes">')
ersetze('</style>', 'body.live #dev,body.live #test{display:none!important}\n#live-leiste{position:fixed;right:10px;top:max(10px,env(safe-area-inset-top));z-index:30}\n</style>')
# Walk-In: Preis eintragen statt fester 60/120 €
ersetze('<label>Stunden<input name="std" type="number" min="1" max="16" value="4"></label>',
        '<label>Stunden<input name="std" type="number" min="1" max="16" value="4"></label>${art === \'walkin\' ? \'<label>Preis brutto (€)<input name="preis" type="number" step="0.01" min="0" inputmode="decimal" placeholder="lt. Preisliste"></label><label>Angebot (AN-CS-…)<input name="angebot" placeholder="optional"></label>\' : \'\'}')
# Start: im Live-Betrieb keine Beispieldaten
ersetze('seed(); ausHash();',
        'window.CS = { S, render, toast, meldung, alertKarte, ST, STUDIOS, TAGE, HEUTE, TARIFE, PTYPEN, ROLLEN, PARTNER, RECHTE, EVENTS, ARTIKEL, datum, abs, fmt, eur, esc, guthaben, belegt, eventPreis };\nif (window.CS_CONFIG) { window.CS_LIVE = true; } else { seed(); ausHash(); }')
ersetze('</body>', '<script src="https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2.49.4/dist/umd/supabase.min.js"></script>\n<script src="live.js"></script>\n</body>')
ersetze('<script>\n{', '<script src="config.js"></script>\n<script>\n{')
ersetze('function abrechnung(partner) {\n  const zeilen = [];', 'function abrechnung(partner) {\n  if (window.CS_ABR) return window.CS_ABR(partner);\n  const zeilen = [];')
ersetze('${esc(PARTNER[a2.partner].name.toUpperCase())}', '${esc((PARTNER[a2.partner]?.name || \'Team\').toUpperCase())}')
ersetze("function naechsteKN() { return 'KN-' + (Math.max(...Object.values(S.kunden).map((v) => +v.kn.slice(3))) + 1); }",
        "function naechsteKN() { return 'KN - ' + String(Math.max(0, ...Object.values(S.kunden).map((v) => +((String(v.kn).match(/(\\d+)/) || [0, 0])[1]))) + 1).padStart(3, '0'); }")
ersetze('${kunde ? `<div class="zeile"><span class="hinweis">Kundennummer</span><b class="mono" style="color:var(--gelb)">${naechsteKN()}</b></div>` : \'\'}',
        '${kunde ? `<label>Kundennummer (bestehende KN übernehmen)<input name="kn" value="${naechsteKN()}" autocomplete="off" style="min-height:48px"></label>` : \'\'}')
(ROOT / 'docs' / 'index.html').write_text(src)
print('web/index.html gebaut,', len(src), 'Zeichen')
