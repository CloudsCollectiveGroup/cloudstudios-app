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
        '<title>CloudStudios</title>\n<meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">\n<meta name="apple-mobile-web-app-title" content="CloudStudios">\n<link rel="manifest" href="manifest.json">\n<link rel="apple-touch-icon" href="bilder/icon-192.png">\n<meta name="apple-mobile-web-app-capable" content="yes">')
ersetze('</style>', 'body.live #dev,body.live #test{display:none!important}\n#live-leiste{position:absolute;right:12px;top:calc(env(safe-area-inset-top) + 14px);z-index:30}\nhtml{background:#05060B}\n.vollbild .handy{padding-top:calc(18px + env(safe-area-inset-top))}\n.vollbild .toast{top:calc(12px + env(safe-area-inset-top))}\n\n/* ---------- Große Bildschirme: iPad, MacBook, Mac Studio ---------- */\n@media (min-width: 820px) {\n  .vollbild .handy{max-width:1320px;padding:calc(28px + env(safe-area-inset-top)) 36px 56px 140px}\n  .vollbild .handynav{left:18px;top:50%;bottom:auto;transform:translateY(-50%);width:100px;max-width:none;flex-direction:column;justify-content:flex-start;gap:6px;padding:12px 8px;border-radius:30px}\n  .vollbild .handynav button{flex:none;min-height:66px;width:100%;font-size:11.5px}\n  .vollbild .toast{left:calc(50% + 60px)}\n  .handy form{max-width:760px}\n  .handy .liste:has(> .karte):not(form):not(:has(form,input,select,textarea)){display:grid;grid-template-columns:repeat(auto-fill,minmax(320px,1fr));gap:10px}\n  .handy .raster:not(:has(input,select,textarea))[style*="repeat(2"]{grid-template-columns:repeat(4,minmax(0,1fr))!important}\n  .handy h2{font-size:34px}\n  #live-leiste{position:fixed;right:24px;top:calc(20px + env(safe-area-inset-top))}\n}\n@media (min-width: 1280px) {\n  .vollbild .handy{padding-left:180px}\n  .vollbild .handynav{width:132px;left:24px}\n  .vollbild .handynav button{flex-direction:row;justify-content:flex-start;gap:10px;padding:0 14px;min-height:52px;font-size:13px}\n  .handy .liste:has(> .karte):not(form):not(:has(form,input,select,textarea)){grid-template-columns:repeat(auto-fill,minmax(360px,1fr))}\n}\n@media (hover: hover) { button:hover:not(:disabled){filter:brightness(1.12)} .karte[data-detail]:hover{border-color:rgba(77,163,255,.5);cursor:pointer} }\n</style>')
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
print('docs/index.html gebaut,', len(src), 'Zeichen')
