// CloudStudios App · Live-Anbindung an Supabase
// Die Oberfläche (index.html) bleibt wie im Prototyp. Diese Datei lädt die echten Daten,
// übersetzt sie in das Format der Oberfläche und schickt jede Aktion an die Datenbank.
(() => {
  if (!window.CS_LIVE || !window.CS) return;
  const C = window.CS, S = C.S, cfg = window.CS_CONFIG;
  const sb = window.supabase.createClient(cfg.url, cfg.key, { auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: true } });
  window.CS_SB = sb;
  const app = document.getElementById('app');
  document.body.classList.add('live');
  const TZ = 'Europe/Berlin';
  let D = null, ICH = null, ABR = {};
  const H = new URLSearchParams((location.hash || '').slice(1));
  const zugang = H.get('zugang') ? { token: H.get('zugang'), typ: H.get('typ') === 'recovery' ? 'recovery' : 'invite' } : null;
  const linkTyp = zugang?.typ || /type=(invite|recovery)/.exec(location.hash || '')?.[1] || null;
  const linkFehler = /error_code=([^&]+)/.exec(location.hash || '')?.[1] || (/error=([^&]+)/.exec(location.hash || '')?.[1]) || null;

  // ---------- Zeit ----------
  const teile = (d) => Object.fromEntries(new Intl.DateTimeFormat('en-CA', { timeZone: TZ, year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', hourCycle: 'h23' }).formatToParts(d).map((p) => [p.type, p.value]));
  const tagVon = (d) => { const t = teile(d); return Math.round((Date.UTC(+t.year, +t.month - 1, +t.day) - C.HEUTE) / 864e5); };
  const stdVon = (d) => { const t = teile(d); return +t.hour + +t.minute / 60; };
  const tagAusDatum = (s) => { const [y, m, d] = s.split('-').map(Number); return Math.round((Date.UTC(y, m - 1, d) - C.HEUTE) / 864e5); };
  const absVon = (iso) => { const d = new Date(iso); return tagVon(d) * 24 + stdVon(d); };
  const zeitpunkt = (tag, h) => {
    const roh = C.HEUTE + tag * 864e5 + h * 36e5;
    for (const versatz of [1, 2]) { const d = new Date(roh - versatz * 36e5); if (tagVon(d) === tag && Math.abs(stdVon(d) - h) < 0.01) return d.toISOString(); }
    return new Date(roh - 36e5).toISOString();
  };
  const isoTag = (tag) => new Date(C.HEUTE + tag * 864e5).toISOString().slice(0, 10);
  const deDatum = (s) => (s ? s.slice(0, 10).split('-').reverse().join('.') : '');
  const uhr = (iso) => new Intl.DateTimeFormat('de-DE', { timeZone: TZ, hour: '2-digit', minute: '2-digit' }).format(new Date(iso));
  const kurz = (iso) => { const d = new Date(iso), t = tagVon(d); return t === 0 ? uhr(iso) : t === -1 ? 'gestern' : new Intl.DateTimeFormat('de-DE', { timeZone: TZ, day: '2-digit', month: '2-digit' }).format(d); };
  const monatsErster = () => isoTag(0).slice(0, 8) + '01';

  // ---------- Fehlertexte ----------
  const TEXTE = {
    KEIN_ZUGRIFF: 'Dafür fehlt Ihnen die Berechtigung.', NICHT_ANGEMELDET: 'Bitte neu anmelden.', SLOT_BELEGT: 'Dieser Zeitraum ist schon belegt.',
    MINDESTENS_2_STUNDEN: 'Mindestens 2 Stunden.', UNGUELTIGE_DAUER: 'Bitte ganze oder halbe Stunden wählen.', VERGANGENHEIT: 'Dieser Zeitpunkt liegt in der Vergangenheit.',
    NUR_AUF_ANFRAGE: 'Dieses Studio ist nur auf Anfrage buchbar.', NUR_VERANSTALTUNG: 'Die Lounge gibt es nur für Veranstaltungen.', STUDIO_INAKTIV: 'Dieses Studio ist gerade nicht buchbar.',
    KONTO_GESPERRT: 'Dieses Konto ist gesperrt.', KUNDE_FEHLT: 'Bitte Kunde wählen.', BEREITS_BEGONNEN: 'Die Session hat schon begonnen.', NICHT_STORNIERBAR: 'Nicht mehr stornierbar.',
    RECHNUNG_FEHLT: 'Bitte Rechnungsnummer angeben.', NICHT_ANGEFRAGT: 'Diese Anfrage ist nicht mehr offen.', REGELN_NICHT_AKZEPTIERT: 'Bitte die Regeln bestätigen.',
    TEXT_FEHLT: 'Bitte kurz beschreiben.', BEGRUENDUNG_FEHLT: 'Bitte Begründung angeben.', TARIF_UNBEKANNT: 'Tarif unbekannt.', SCHON_ENTSCHIEDEN: 'Schon entschieden.'
  };
  const fehlerText = (e) => {
    const m = String(e?.message || e || '').trim(), code = m.split(':')[0];
    if (code === 'ZU_WENIG_CREDITS') return `Zu wenig Credits. Reicht für ${C.fmt(+m.split(':')[1] || 0)} Std.`;
    if (code === 'PARTNER_GRENZE') return `In Partnerstudios sind diesen Monat noch ${C.fmt(+m.split(':')[1] || 0)} Credits Ihrer Mitgliedschaft nutzbar.`;
    return TEXTE[code] || m || 'Unbekannter Fehler.';
  };
  async function rpc(name, args) { const { data, error } = await sb.rpc(name, args); if (error) throw error; return data; }

  // ---------- Daten laden und abbilden ----------
  const POSTEN_NAME = { paket: 'Paket', bonus: 'Bonus', mitglied: 'Mitglied', label: 'Label-Credits', basement: 'Basement-Pauschale', korrektur: 'Korrektur' };
  function platzhalter(id) { if (id && !S.kunden[id]) S.kunden[id] = { name: 'Konto', kn: '—', mitglied: null, tel: '—', status: 'Freigegeben', seit: '', notiz: '' }; }

  function abbilden(d) {
    D = d; ICH = d.ich;
    const team = ['admin', 'team'].includes(ICH.rolle);
    S.sicht = team ? 'intern' : ICH.rolle === 'partner' ? 'partner' : 'kunde';
    if (ICH.rolle === 'partner') S.partner = ICH.partner;
    if (ICH.rolle === 'kunde') S.kunde = ICH.id;

    // Tarife
    for (const k of Object.keys(C.TARIFE)) delete C.TARIFE[k];
    C.PTYPEN.length = 0;
    for (const t of d.tarife || []) {
      if (t.art === 'mitglied') C.TARIFE[t.id] = { name: t.name, cr: +t.credits_monat, nur: t.nur_studios || undefined, einladung: t.nur_einladung, brutto: +t.beitrag_brutto };
      if (t.art === 'basement') C.PTYPEN.push({ id: t.id, name: `${t.id} ${t.name}`, cr: +t.credits_monat, brutto: +t.beitrag_brutto, nur: t.nur_studios || ['s3'], partner: 'basement' });
    }

    // Kunden
    S.kunden = {};
    for (const k of d.kunden) {
      S.kunden[k.id] = { name: k.name, kn: k.kn || '—', mail: k.mail, tel: k.tel || '—', status: 'Freigegeben', seit: k.seit || '', notiz: k.notiz || '',
        mitglied: k.basement ? 'Basement-Pauschale · ' + (k.tarif_id || 'PA 230') : k.mitglied || null, label: k.label ? 'Artist' : undefined };
    }
    S.gesperrt = d.kunden.filter((k) => !k.aktiv).map((k) => k.id);
    S.pauschalen = d.kunden.filter((k) => k.basement).map((k) => ({ kunde: k.id, name: k.tarif_id || 'PA 230', brutto: C.PTYPEN.find((t) => t.id === k.tarif_id)?.brutto || 300 }));

    // Credit-Posten (credits = Rest; Zuordnungen rechnet die Datenbank)
    S.zuord = [];
    S.posten = d.posten.filter((p) => +p.rest > 0).map((p) => ({ id: p.id, kunde: p.kunde, credits: +p.rest, original: +p.credits,
      art: p.art === 'paket' ? 'Paket ' + C.fmt(+p.credits) : (p.notiz && ['mitglied', 'basement'].includes(p.art) ? p.notiz : POSTEN_NAME[p.art] || p.art),
      bis: deDatum(p.bis), bisAbs: tagAusDatum(p.bis) * 24 + 24, nur: p.nur || null, rn: p.rn || '', basement: p.art === 'basement' }));
    S.posten.forEach((p) => platzhalter(p.kunde));

    // Buchungen
    S.buchungen = d.buchungen.map((b) => {
      const beginn = new Date(b.beginn), tag = tagVon(beginn), von = Math.round(stdVon(beginn) * 2) / 2, dauer = Math.round((new Date(b.ende) - beginn) / 18e5) / 2;
      const x = { id: b.id, studio: b.studio, tag, von, bis: Math.min(24, von + dauer), status: b.status, kunde: b.kunde || null, credits: +b.credits || 0, extras: [],
        erstattet: !!b.erstattet, grund: b.grund || null, partner: b.partner || null, gruppe: b.gruppe || null, gast: b.gast || null, kn: b.kn || null,
        preis: b.preis != null ? +b.preis : null, angebot: b.angebot || null, rechnung: b.rechnung || null, noShow: !!b.noshow,
        reserviertBis: b.reserviert_bis ? absVon(b.reserviert_bis) : null, stornoAm: b.storniert_am ? uhr(b.storniert_am) : null, stornoVon: b.storniert_von || null };
      if (!team && !b.eigen) { x.kunde = null; x.gast = null; if (x.status === 'angefragt') x.reserviertBis = 9e9; }
      if (team && !x.kunde && !x.gast && x.status === 'gebucht') x.gast = 'Buchung';
      if (x.credits === 0 && x.gast) x.walkin = true;
      platzhalter(x.kunde);
      return x;
    });

    // Anfragen (Paket, Veranstaltung, Shop, Problem), Studio-5-Bewerbungen, Zustandsmeldungen
    S.anfragen = [];
    for (const a of d.anfragen) {
      platzhalter(a.kunde);
      const x = { id: a.id, art: a.art || 'problem', kunde: a.kunde, text: a.text, status: ['offen', 'in_klaerung'].includes(a.status) ? 'offen' : 'erledigt' };
      const dt = a.daten || {};
      if (x.art === 'paket' || x.art === 'label') x.menge = +dt.menge || 0;
      if (x.art === 'event' && dt.datum) Object.assign(x, { tag: tagAusDatum(dt.datum), start: +dt.start, ende: +dt.ende, camp: +dt.camp || 0, eventArt: dt.eventArt || 'release' });
      if (x.art === 'bestellung') x.posten = dt.posten || [];
      S.anfragen.push(x);
    }
    S.bewerbungen = {};
    for (const w of d.bewerbungen || []) {
      platzhalter(w.kunde);
      const bew = { kuenstler: w.kuenstler, link: w.link, hoerer: w.hoerer_stufe, releases: w.releases_stufe, label: w.label || '', projekt: w.projekt, engineer: w.engineer, regeln: w.regeln };
      if (!S.bewerbungen[w.kunde]) S.bewerbungen[w.kunde] = bew;
      const beginn = new Date(w.wunsch_start), tag = tagVon(beginn), start = stdVon(beginn);
      S.anfragen.push({ id: 1e6 + w.id, dbBewerbung: w.id, art: 's5', kunde: w.kunde, status: ['offen', 'zugesagt'].includes(w.status) ? 'offen' : 'erledigt',
        partnerEntscheid: w.status === 'zugesagt' ? 'ja' : w.status === 'abgelehnt' ? 'nein' : undefined, tag, start, std: +w.stunden, bew,
        text: `Studio 5: ${C.TAGE[tag] || deDatum(w.wunsch_start)}, ${start}–${start + +w.stunden} Uhr · ${w.projekt}` });
    }
    for (const z of d.zustand || []) {
      platzhalter(z.kunde);
      S.anfragen.push({ id: 2e6 + z.id, dbZustand: z.id, art: 'zustand', partner: z.partner, kunde: z.kunde, buchung: z.buchung, text: z.text,
        raumName: z.raum === 'gemein' ? 'Küche & Chill-Area' : C.ST[z.raum]?.name || z.raum, foto: z.foto ? '📷 Foto' : '', fotoPfad: z.foto, status: z.status === 'offen' ? 'offen' : 'erledigt' });
    }
    S.s5frei = (d.freigaben || []).filter((f) => f.studio === 's5').map((f) => { if (!S.kunden[f.kunde]) S.kunden[f.kunde] = { name: f.name, kn: f.kn || '—', tel: '—', status: 'Freigegeben', notiz: '' }; return f.kunde; });

    // Partner-Mitteilungen, Gutschrift-Bestätigungen
    S.brett = (d.mitteilungen || []).map((m) => ({ id: m.id, partner: m.partner, von: m.von, text: m.text, zeit: kurz(m.am), neu: !m.gelesen }));
    S.geprueft = {};
    for (const g of d.gutschriften || []) if (g.monat === monatsErster()) S.geprueft[g.partner] = deDatum(g.am) + ' ' + uhr(g.am);

    // Team, Rechte, Einstellungen
    if (d.konten) {
      S.team = d.konten.filter((k) => k.rolle !== 'partner').map((k) => ({ id: k.id, name: k.name, mail: k.mail || '', rolle: k.rolle === 'admin' ? 'admin' : k.team_rolle || 'buchung' }));
      S.zugaenge = d.konten.filter((k) => k.rolle === 'partner').map((k) => ({ id: k.id, name: k.name, mail: k.mail || '', partner: k.partner }));
    } else { S.team = []; S.zugaenge = []; }
    S.rechte = Object.assign({ buchung: [], geld: [], marketing: [], betrieb: [], records: [] }, d.rechte || {}, { admin: C.RECHTE.map((r) => r[0]) });
    const e = d.einstellungen || {};
    S.einst = { partnerMax220: +((d.tarife || []).find((t) => t.id === 'PA 220')?.partner_max_monat ?? 30), minHoerer: +(e.s5_min_hoerer ?? 2), minReleases: +(e.s5_min_releases ?? 1), ohneNoShow: e.s5_ohne_noshow !== false };

    // Türcodes
    S.codes = {};
    for (const [tag, code] of Object.entries(d.codes || {})) S.codes[tagAusDatum(tag)] = code;

    // Protokoll
    S.protokoll = (d.protokoll || []).map((l) => ({ zeit: kurz(l.am), wer: l.wer, text: protokollText(l) }));
    S.meldungen = []; S.gutscheine = [];
    if (!S._mtab) { S.mTab = S.mTab || 'kunden'; S._mtab = true; }
  }

  function protokollText(l) {
    const x = l.details || {}, st = (id) => C.ST[id]?.name || id || '';
    switch (l.aktion) {
      case 'credits_buchen': return `${st(x.studio)} gebucht (${C.fmt(+x.credits || 0)} Credits)`;
      case 'stornieren': return x.halb ? 'Storno (halbe Credits angerechnet)' : `Storno${x.erstattet ? ', Credits zurück' : ''}${x.kulanz ? ' (Kulanz)' : ''}`;
      case 'anfrage_eintragen': return `Walk-In eingetragen: ${st(x.studio)}`;
      case 'zahlung_bestaetigen': return `Zahlung bestätigt${x.rechnung ? ' · ' + x.rechnung : ''}`;
      case 'blockieren': return `${st(x.studio)} ${x.geschlossen ? 'geschlossen' : 'blockiert'}`;
      case 'credits_aufladen': return `${C.fmt(+x.credits || 0)} Credits aufgeladen (${x.art})`;
      case 'korrektur': return `Korrektur ${x.credits > 0 ? '+' : ''}${x.credits}: ${x.notiz}`;
      case 'veranstaltung_eintragen': return `Veranstaltung: ${x.titel || ''}`;
      default: return l.aktion.replace(/_/g, ' ');
    }
  }

  async function abrechnungLaden() {
    ABR = {};
    if (!(ICH.rolle === 'admin' || ICH.rolle === 'partner')) return;
    try {
      const rows = await rpc('partner_abrechnung', { p_monat: monatsErster() });
      for (const r of rows || []) (ABR[r.partner] = ABR[r.partner] || []).push({ t: `${r.posten} (${C.fmt(+r.menge)})`, b: +r.betrag });
    } catch (_) { /* ohne Abrechnung weiter */ }
    LABEL = [];
    if (ICH.rolle === 'admin') {
      try { LABEL = (await rpc('label_verbrauch', { p_monat: monatsErster() }) || []).map((r) => ({ name: r.name, kn: r.kn, tarif: r.tarif, credits: +r.credits, netto: +r.betrag_netto })); } catch (_) { LABEL = []; }
    }
  }
  let LABEL = [];
  window.CS_LABEL = () => LABEL;
  window.CS_ABR = (partner) => (ABR[partner] && ABR[partner].length ? ABR[partner] : [{ t: 'Noch keine Umsätze in diesem Monat', b: 0 }]);

  let ladeLauf = null;
  async function laden() {
    if (ladeLauf) return ladeLauf;
    ladeLauf = (async () => {
      try { abbilden(await rpc('app_daten', {})); await abrechnungLaden(); C.render(); leiste(); if (S.kontoMeldung) C.meldung('f-konto-msg', S.kontoMeldung.t, S.kontoMeldung.ok); }
      finally { ladeLauf = null; }
    })();
    return ladeLauf;
  }
  async function nach(aktion, erfolg) {
    try { await aktion(); await laden(); if (erfolg) C.toast(erfolg); return true; }
    catch (e) { C.toast(fehlerText(e)); return false; }
  }

  // ---------- Anmelden ----------
  const css = 'min-height:48px;width:100%';
  function anmeldeSeite(meldung = '') {
    app.classList.remove('vollbild');
    app.innerHTML = `<div style="max-width:400px;margin:10vh auto 0;padding:0 16px">
      <div class="karte" style="padding:22px">
        <div class="mono" style="color:var(--marke)">CLOUDSTUDIOS</div><h2 style="margin-top:6px">Anmelden</h2>
        <form id="live-login" class="liste" style="margin-top:14px;gap:10px">
          <label>E-Mail<input name="mail" type="email" autocomplete="username" required style="${css}"></label>
          <label>Passwort<input name="pw" type="password" autocomplete="current-password" required style="${css}"></label>
          <button class="primaer" type="submit" style="min-height:52px">Anmelden</button>
        </form>
        <div id="live-msg" class="hinweis" style="margin-top:10px;color:#FF8A8D">${C.esc(meldung)}</div>
        <div class="hinweis" style="margin-top:10px">Noch kein Zugang oder Passwort vergessen? Bitte beim CloudStudios-Team melden. Sie bekommen dann einen persönlichen Link.</div>
      </div></div>`;
  }
  function passwortSeite() {
    app.classList.remove('vollbild');
    app.innerHTML = `<div style="max-width:400px;margin:10vh auto 0;padding:0 16px"><div class="karte" style="padding:22px">
      <div class="mono" style="color:var(--marke)">CLOUDSTUDIOS</div><h2 style="margin-top:6px">${linkTyp === 'invite' ? 'Willkommen' : 'Neues Passwort'}</h2>
      <div class="hinweis" style="margin-top:6px">Legen Sie Ihr Passwort fest. Mindestens 10 Zeichen.</div>
      <form id="live-pw" class="liste" style="margin-top:14px;gap:10px">
        <label>Passwort<input name="pw" type="password" autocomplete="new-password" minlength="10" required style="${css}"></label>
        <label>Wiederholen<input name="pw2" type="password" autocomplete="new-password" minlength="10" required style="${css}"></label>
        <button class="primaer" type="submit" style="min-height:52px">Speichern und weiter</button>
      </form><div id="live-msg" class="hinweis" style="margin-top:10px;color:#FF8A8D"></div></div></div>`;
  }
  function leiste() {
    let el = document.getElementById('live-leiste');
    if (!el) { el = document.createElement('div'); el.id = 'live-leiste'; document.body.appendChild(el); }
    if (ICH) setTimeout(() => pushPruefen(), 1500);
    el.innerHTML = ICH ? `<button data-live-push style="min-height:36px;padding:0 12px;border-radius:999px;font-size:12px;opacity:.85;margin-right:6px" title="Push-Mitteilungen">🔔 Mitteilungen</button><button data-live-aus style="min-height:36px;padding:0 12px;border-radius:999px;font-size:12px;opacity:.75" title="${C.esc(ICH.name)}">Abmelden</button>` : '';
  }

  // ---------- Push-Mitteilungen ----------
  const PUSH_ARTEN = {
    kunde: [['bestaetigt', 'Buchung bestätigt'], ['verbindlich', 'Buchung verbindlich (24 Std. vorher, Türcode in der App)'], ['storno', 'Storno oder abgelaufene Reservierung'], ['ablauf', 'Credits laufen in 7 Tagen ab']],
    partner: [['p_buchung', 'Neue Buchung in Ihrem Studio'], ['p_storno', 'Stornierung in Ihrem Studio'], ['mitteilung', 'Mitteilung von CloudStudios'], ['abrechnung', 'Abrechnung zur Prüfung (am 1.)']],
    team: [['anfrage', 'Neue Anfrage'], ['buchung', 'Buchungen und Stornos'], ['zahlung', 'Offene Zahlungen (täglich ab 10 Uhr)'], ['mitteilung', 'Mitteilungen von Partnern'], ['zustand', 'Zustandsmeldungen']],
  };
  const pushArten = () => {
    const r = ICH?.rolle; let l = r === 'kunde' ? PUSH_ARTEN.kunde : r === 'partner' ? PUSH_ARTEN.partner.slice() : PUSH_ARTEN.team.slice();
    if (r === 'admin' || (r === 'partner' && ICH.partner === 'blackclouds')) l.push(['bewerbung', 'Studio-5-Bewerbungen']);
    return l;
  };
  const pushMoeglich = () => 'serviceWorker' in navigator && 'PushManager' in window && 'Notification' in window;
  const istIOS = () => /iPhone|iPad|iPod/.test(navigator.userAgent) || (navigator.platform === 'MacIntel' && navigator.maxTouchPoints > 1);
  const alsApp = () => window.matchMedia('(display-mode: standalone)').matches || navigator.standalone === true;
  const b64 = (s) => { const p = '='.repeat((4 - (s.length % 4)) % 4), r = atob((s + p).replace(/-/g, '+').replace(/_/g, '/')); return Uint8Array.from(r, (c) => c.charCodeAt(0)); };
  const geraetName = () => { const u = navigator.userAgent; return (/iPhone/.test(u) ? 'iPhone' : /iPad/.test(u) ? 'iPad' : /Android/.test(u) ? 'Android' : /Mac/.test(u) ? 'Mac' : /Windows/.test(u) ? 'Windows' : 'Gerät') + (alsApp() ? ' · App' : ' · Browser'); };
  async function swReg() { return navigator.serviceWorker.getRegistration() .then((r) => r || navigator.serviceWorker.register('sw.js')); }
  let PUSH = { offen: false, laden: false, status: null, hier: false, meldung: '' };
  // Gerät mit veraltetem Schlüssel neu anmelden (sonst kommen keine Mitteilungen an)
  let pushGeprueft = false;
  async function pushPruefen() {
    if (pushGeprueft || !ICH || !pushMoeglich() || Notification.permission !== 'granted') return;
    pushGeprueft = true;
    try {
      const reg = await swReg(); const sub = await reg.pushManager.getSubscription(); if (!sub) return;
      const schluessel = await rpc('push_oeffentlich'); if (!schluessel) return;
      const soll = b64(schluessel), ist = new Uint8Array(sub.options?.applicationServerKey || new ArrayBuffer(0));
      const gleich = ist.length === soll.length && ist.every((x, i) => x === soll[i]);
      let neu = sub;
      if (!gleich) {
        try { await rpc('push_abo_loeschen', { p_endpoint: sub.endpoint }); } catch (_) {}
        await sub.unsubscribe();
        await navigator.serviceWorker.ready;
        neu = await reg.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: soll });
      }
      const j = neu.toJSON();
      await rpc('push_abo_speichern', { p_endpoint: j.endpoint, p_p256dh: j.keys.p256dh, p_auth: j.keys.auth, p_geraet: geraetName() });
    } catch (_) { pushGeprueft = false; }
  }
  async function pushLaden() {
    await pushPruefen().catch(() => {});
    PUSH.laden = true; pushZeigen();
    try {
      PUSH.status = await rpc('push_status');
      PUSH.hier = false;
      if (pushMoeglich() && Notification.permission === 'granted') {
        const reg = await swReg(); const sub = await reg.pushManager.getSubscription();
        PUSH.hier = !!sub && (PUSH.status.endpoints || []).includes(sub.endpoint);
        if (sub && !PUSH.hier) { const j = sub.toJSON(); await rpc('push_abo_speichern', { p_endpoint: j.endpoint, p_p256dh: j.keys.p256dh, p_auth: j.keys.auth, p_geraet: geraetName() }); PUSH.hier = true; PUSH.status = await rpc('push_status'); }
      }
    } catch (e) { PUSH.meldung = 'Konnte den Status nicht laden.'; }
    PUSH.laden = false; pushZeigen();
  }
  function pushZeigen() {
    let el = document.getElementById('live-push');
    if (!PUSH.offen) { if (el) el.remove(); return; }
    if (!el) { el = document.createElement('div'); el.id = 'live-push'; document.body.appendChild(el); }
    const aus = new Set(PUSH.status?.aus || []);
    let kopf;
    if (!pushMoeglich() && istIOS() && !alsApp()) kopf = `<div class="hinweis" style="color:#FFD27A">Auf dem iPhone funktionieren Push-Mitteilungen nur aus der App auf dem Home-Bildschirm: in Safari unten auf <b>Teilen</b> tippen, dann <b>„Zum Home-Bildschirm“</b>. Danach die App von dort öffnen und hier einschalten.</div>`;
    else if (!pushMoeglich()) kopf = `<div class="hinweis">Dieser Browser kann keine Push-Mitteilungen empfangen.</div>`;
    else if (Notification.permission === 'denied') kopf = `<div class="hinweis" style="color:#FF8A8D">Mitteilungen sind für diese App in den Geräte-Einstellungen blockiert. Dort erlauben, dann hier einschalten.</div>`;
    else kopf = PUSH.hier
      ? `<div class="zeile" style="gap:8px;align-items:center"><span style="color:#7FE0AE">● Auf diesem Gerät eingeschaltet</span><button data-push-aus style="margin-left:auto;min-height:36px;font-size:12px">Ausschalten</button></div>`
      : `<button class="primaer" data-push-an style="width:100%;min-height:50px">Push auf diesem Gerät einschalten</button>`;
    el.innerHTML = `<div style="position:fixed;inset:0;z-index:60;background:rgba(0,0,0,.55);display:flex;align-items:flex-end;justify-content:center" data-push-zu>
      <div class="karte" style="width:min(520px,100%);max-height:88vh;overflow:auto;border-radius:26px 26px 0 0;padding:20px 18px calc(24px + env(safe-area-inset-bottom));background:linear-gradient(180deg,rgba(22,28,44,.98),rgba(8,11,20,.99))">
        <div class="zeile" style="align-items:center"><h3 style="font-size:20px;margin:0">Push-Mitteilungen</h3><button data-push-zu style="margin-left:auto;width:40px;min-height:40px;padding:0">✕</button></div>
        <div class="hinweis" style="margin:6px 0 14px">Mitteilungen direkt aufs Handy. Gilt pro Gerät; die Auswahl unten gilt für alle Ihre Geräte.</div>
        ${PUSH.laden ? '<div class="hinweis">Lädt …</div>' : kopf}
        <div class="mono" style="margin-top:18px">WORÜBER?</div>
        <div class="liste" style="margin-top:8px;gap:6px">${pushArten().map(([k, n]) => `<label class="karte" style="display:flex;flex-direction:row;align-items:center;justify-content:flex-start;text-align:left;gap:12px;padding:12px 14px;cursor:pointer;font-size:15px;color:var(--ink,#F2F4F8)"><input type="checkbox" data-push-art="${k}" ${aus.has(k) ? '' : 'checked'} style="flex:none;width:22px !important;height:22px !important;min-height:0 !important;padding:0 !important;accent-color:#4DA3FF;margin:0"><span style="flex:1">${C.esc(n)}</span></label>`).join('')}</div>
        ${PUSH.status?.geraete ? `<div class="hinweis" style="margin-top:10px">${PUSH.status.geraete} ${PUSH.status.geraete === 1 ? 'Gerät' : 'Geräte'} eingeschaltet.</div><button data-push-test style="margin-top:10px;width:100%;min-height:44px">Testmitteilung senden</button>` : ''}
        <div class="hinweis" id="live-push-msg" style="margin-top:10px">${C.esc(PUSH.meldung || '')}</div>
      </div></div>`;
  }
  document.addEventListener('click', async (e) => {
    const t = e.target.closest('[data-live-push],[data-push-zu],[data-push-an],[data-push-aus],[data-push-test]'); if (!t) return;
    e.stopImmediatePropagation();
    const d = t.dataset;
    if ('pushZu' in d) { if (e.target === t || t.tagName === 'BUTTON') { PUSH.offen = false; pushZeigen(); } return; }
    if ('livePush' in d) { PUSH.offen = true; PUSH.meldung = ''; pushLaden(); return; }
    if ('pushAn' in d) {
      try {
        const erlaubt = await Notification.requestPermission();
        if (erlaubt !== 'granted') { PUSH.meldung = 'Ohne Erlaubnis keine Mitteilungen.'; pushZeigen(); return; }
        const reg = await swReg(); await navigator.serviceWorker.ready;
        let sub = await reg.pushManager.getSubscription();
        if (!sub) { const schluessel = await rpc('push_oeffentlich'); if (!schluessel) { PUSH.meldung = 'Push wird gerade eingerichtet. Bitte in ein paar Minuten nochmal.'; pushZeigen(); return; } sub = await reg.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: b64(schluessel) }); }
        const j = sub.toJSON();
        await rpc('push_abo_speichern', { p_endpoint: j.endpoint, p_p256dh: j.keys.p256dh, p_auth: j.keys.auth, p_geraet: geraetName() });
        PUSH.meldung = 'Eingeschaltet.'; await pushLaden();
      } catch (err) { PUSH.meldung = 'Einschalten hat nicht geklappt. Bitte nochmal versuchen.'; pushZeigen(); }
      return;
    }
    if ('pushAus' in d) {
      try { const reg = await swReg(); const sub = await reg.pushManager.getSubscription(); if (sub) { await rpc('push_abo_loeschen', { p_endpoint: sub.endpoint }); await sub.unsubscribe(); } PUSH.meldung = 'Auf diesem Gerät ausgeschaltet.'; await pushLaden(); }
      catch (_) { PUSH.meldung = 'Ausschalten hat nicht geklappt.'; pushZeigen(); }
      return;
    }
    if ('pushTest' in d) {
      try { await rpc('push_test'); PUSH.meldung = 'Testmitteilung ist unterwegs – sollte in wenigen Sekunden ankommen.'; }
      catch (_) { PUSH.meldung = 'Test fehlgeschlagen.'; }
      pushZeigen(); return;
    }
  }, true);
  document.addEventListener('change', async (e) => {
    const k = e.target.dataset?.pushArt; if (!k) return;
    const aus = new Set(PUSH.status?.aus || []); if (e.target.checked) aus.delete(k); else aus.add(k);
    try { await rpc('push_einstellungen_setzen', { p_aus: [...aus] }); PUSH.status = { ...PUSH.status, aus: [...aus] }; }
    catch (_) { e.target.checked = !e.target.checked; PUSH.meldung = 'Nicht gespeichert.'; pushZeigen(); }
  }, true);
  if ('serviceWorker' in navigator) navigator.serviceWorker.register('sw.js').catch(() => {});

  // ---------- Aktionen ----------
  document.addEventListener('click', (e) => { if (e.target.closest('[data-kontoart]')) S.kontoMeldung = null; }, true);
  const UI_ONLY = ['aktezu', 'detailzu', 'detail', 'testzu', 'testliste', 'devtoggle', 'ansicht', 'ktag', 'kftag', 'kpTag', 'ktab', 'fstudio', 'fextra', 'galerie', 'raumzu', 'raum',
    'raumbuchen', 'ptab', 'etab', 'kontoart', 'brettziel', 'akte', 'mtab', 'ikal', 'itab', 'iart', 'schnell', 'korbplus', 'korbminus', 'bmodus', 'eart', 'egetraenk', 'esnacks', 'aufmax', 'gelesen'];
  const anfrage = (id) => S.anfragen.find((x) => x.id === +id);
  const buchung = (id) => S.buchungen.find((x) => x.id === +id);
  const frage = (text, vorschlag = '') => { const r = window.prompt(text, vorschlag); return r === null ? null : r.trim(); };

  document.addEventListener('click', async (e) => {
    const t = e.target.closest('button'); if (!t) return;
    const d = t.dataset;
    if ('liveKopieren' in d) {
      e.stopImmediatePropagation();
      try { await navigator.clipboard.writeText(d.liveKopieren); C.toast('Link kopiert. Jetzt in WhatsApp einfügen.'); }
      catch (_) { window.prompt('Link kopieren:', d.liveKopieren); }
      return;
    }
    if ('liveNeulink' in d) {
      e.stopImmediatePropagation();
      const k = S.kunden[d.liveNeulink];
      if (!k?.mail) return C.toast('Für dieses Konto ist keine E-Mail hinterlegt.');
      const { data, error } = await sb.functions.invoke('einladen', { body: { neuer_link: true, mail: k.mail, redirect: location.origin + location.pathname } });
      if (error || !data?.link) { let t = error?.message || 'Fehler'; try { t = (await error.context.json()).fehler || t; } catch (_) {} return C.toast('Kein Link: ' + t); }
      S.akte = null; S.iTab = 'mehr'; S.mTab = 'konten'; S.einladung = { name: k.name, mail: k.mail, tel: k.tel, link: data.link, ansicht: 'Kunden-App' }; S.kontoMeldung = null;
      C.render(); window.scrollTo(0, document.body.scrollHeight); return;
    }
    if ('liveAus' in d) { e.stopImmediatePropagation(); await sb.auth.signOut(); location.hash = ''; location.reload(); return; }
    if (!ICH) return;
    const keys = Object.keys(d);
    if (!keys.length || keys.every((k) => UI_ONLY.includes(k) || k === 'zu' || k === 'anker' || ['ktag', 'kftag', 'kptag', 'testpause', 'testhin', 'testok'].includes(k))) {
      if ('mtab' in d && d.mtab === 'mitteilungen' && S.brettZiel) rpc('mitteilungen_gelesen', { p_partner: S.brettZiel }).catch(() => {});
      if ('ptab' in d && d.ptab === 'kontakt') rpc('mitteilungen_gelesen', { p_partner: S.partner }).catch(() => {});
      return; // reine Navigation: der Prototyp-Code macht das
    }
    e.stopImmediatePropagation(); e.preventDefault();
    t.disabled = true;
    try {
      if (d.zahlung) { const rn = frage('Rechnungsnummer (RN-CS-…), leer lassen wenn noch keine:'); if (rn === null) return; await nach(() => rpc('zahlung_bestaetigen', { p_buchung: +d.zahlung, p_rechnung: rn || null }), 'Zahlung bestätigt.'); return; }
      if (d.labelok) {
        const a = anfrage(d.labelok);
        await nach(async () => { await rpc('credits_aufladen', { p_kunde: a.kunde, p_art: 'label', p_credits: a.menge, p_notiz: 'Nachbuchung Label-Credits' }); await rpc('anfrage_status', { p_id: a.id, p_status: 'erledigt' }); }, `${a.menge} Label-Credits freigegeben.`); return;
      }
      if (d.labelnach) { await nach(() => rpc('anfrage_neu', { p_art: 'label', p_text: `${d.labelnach} Label-Credits nachbuchen`, p_daten: { menge: +d.labelnach } }), 'Anfrage gesendet. Cem gibt die Credits frei.'); return; }
      if (d.aufladen) {
        const a = anfrage(d.aufladen), rn = frage(`Rechnungsnummer für Paket ${a.menge}:`, 'RN-CS-'); if (!rn || rn === 'RN-CS-') return;
        await nach(async () => { await rpc('credits_aufladen', { p_kunde: a.kunde, p_art: 'paket', p_credits: a.menge, p_rechnung: rn }); await rpc('anfrage_status', { p_id: a.id, p_status: 'erledigt' }); }, `${a.menge} Credits aufgeladen.`); return;
      }
      if (d.s5) { const a = anfrage(d.s5); await nach(async () => { await rpc('credits_buchen', { p_studio: 's5', p_start: zeitpunkt(a.tag, a.start), p_stunden: a.std, p_kunde: a.kunde }); }, 'Studio 5 eingetragen.'); return; }
      if (d.ablehnen || d.erledigt) {
        const a = anfrage(d.ablehnen || d.erledigt);
        if (a.dbZustand) await nach(() => rpc('zustand_erledigt', { p_id: a.dbZustand }), 'Erledigt.');
        else if (a.dbBewerbung) await nach(() => rpc('bewerbung_entscheiden', { p_id: a.dbBewerbung, p_zusage: false }), 'Abgelehnt.');
        else await nach(() => rpc('anfrage_status', { p_id: a.id, p_status: d.ablehnen ? 'abgelehnt' : 'erledigt' }), d.ablehnen ? 'Abgelehnt.' : 'Erledigt.');
        return;
      }
      if ('kbuchen' in d) {
        const f = S.form, ex = ['tlm103', 'u87'].filter((x) => f[x]);
        const notiz = ex.length ? 'Extras: ' + ex.map((x) => x === 'u87' ? 'Neumann U87' : 'Neumann TLM 103').join(', ') : null;
        try {
          await rpc('credits_buchen', { p_studio: f.studio, p_start: zeitpunkt(f.tag, f.start), p_stunden: f.std, p_notiz: notiz });
          S.kTab = 'start'; await laden(); C.toast(`Buchung bestätigt: ${C.ST[f.studio].name} ${C.TAGE[f.tag]} ${f.start}–${f.start + f.std} Uhr. Bitte bis ${f.start + f.std - 1}:45 räumen.`);
        } catch (err) {
          const el = document.getElementById('k-msg'), m = String(err.message || '');
          if (el) { el.className = 'karte fehler'; el.style.marginTop = '10px';
            if (m.startsWith('ZU_WENIG_CREDITS')) { const n = +m.split(':')[1]; el.innerHTML = n >= 2 ? `Ihr Guthaben reicht für ${C.fmt(n)} Std. <button class="primaer" data-aufmax="${n}" style="margin-left:6px">${C.fmt(n)} Std. wählen</button>` : 'Ihr Guthaben reicht nicht für 2 Stunden. Im Shop können Sie Credits nachkaufen.'; }
            else el.textContent = fehlerText(err); }
        }
        return;
      }
      if (d.istorno || d.kstorno || d.pfrei || d.kulanz) {
        const b = buchung(d.istorno || d.kstorno || d.pfrei || d.kulanz);
        if (!d.pfrei && !window.confirm('Buchung wirklich stornieren?')) return;
        try {
          const r = await rpc('stornieren', { p_buchung: b.id, p_kulanz: !!d.kulanz });
          await laden();
          C.toast({ ERSTATTET: 'Storniert. Die Credits sind zurück.', HALB_ERSTATTET: 'Storniert. Die Hälfte der Credits ist zurück.', NICHT_ERSTATTET: 'Storniert. Unter der Frist bleiben die Credits abgezogen.', STORNIERT: 'Storniert.' }[r] || 'Storniert.');
        } catch (err) { C.toast(fehlerText(err)); }
        return;
      }
      if (d.recht) { const [r, x] = d.recht.split(':'); await nach(() => rpc('recht_setzen', { p_rolle: r, p_recht: x, p_an: !(S.rechte[r] || []).includes(x) })); return; }
      if (d.sperren) { const weg = S.gesperrt.includes(d.sperren); await nach(() => rpc('profil_setzen', { p_id: d.sperren, p_aktiv: weg }), weg ? 'Konto entsperrt.' : 'Konto gesperrt.'); return; }
      if (d.s5weg) { await nach(() => rpc('freigabe_setzen', { p_kunde: d.s5weg, p_an: false, p_studio: 's5' }), 'Freigabe entzogen.'); return; }
      if ('gprueft' in d) { await nach(() => rpc('gutschrift_bestaetigen', { p_monat: monatsErster() }), 'Danke, bestätigt.'); return; }
      if (d.s5ok || d.s5nein) { const a = anfrage(d.s5ok || d.s5nein); await nach(() => rpc('bewerbung_entscheiden', { p_id: a.dbBewerbung, p_zusage: !!d.s5ok, p_dauerhaft: !!d.dauerhaft }), d.s5ok ? 'Zugesagt. CloudStudios trägt den Termin ein.' : 'Abgelehnt.'); return; }
      if (d.noshow) { const b = buchung(d.noshow); await nach(() => rpc('nicht_erschienen_setzen', { p_buchung: b.id, p_wert: !b.noShow })); return; }
      if (d.paket) { await nach(() => rpc('anfrage_neu', { p_art: 'paket', p_text: `Paket ${d.paket} angefragt`, p_daten: { menge: +d.paket } }), 'Anfrage gesendet. Sie bekommen die Rechnung per Nachricht.'); return; }
      if ('problem' in d) { const txt = frage('Was ist los? Kurz beschreiben:'); if (!txt) return; await nach(() => rpc('anfrage_neu', { p_art: 'problem', p_text: txt }), 'Danke, das Team ist informiert.'); return; }
      if ('s5anfrage' in d) { const f = S.form; await nach(() => rpc('anfrage_neu', { p_art: 's5', p_text: `Studio 5: ${C.TAGE[f.tag]}, ${f.start}–${f.start + f.std} Uhr`, p_studio: 's5', p_daten: { datum: isoTag(f.tag), start: f.start, std: f.std } }), 'Anfrage gesendet.'); return; }
      if ('bestellen' in d) {
        const posten = Object.entries(S.korb).filter(([, n]) => n > 0).map(([id, n]) => ({ id, n }));
        if (!posten.length) return;
        const summe = posten.reduce((x, p) => x + C.ARTIKEL[p.id].preis * p.n, 0);
        await nach(() => rpc('anfrage_neu', { p_art: 'bestellung', p_text: posten.map((p) => `${p.n}× ${C.ARTIKEL[p.id].name}`).join(', ') + ' · ' + C.eur(summe), p_daten: { posten } }), 'Bestellung angefragt. Rechnung und Zahlungsdaten folgen.');
        S.korb = {}; S.widerruf = false; C.render(); return;
      }
      if (d.bestellok) {
        const a = anfrage(d.bestellok), rn = frage('Rechnungsnummer der Bestellung:', 'RN-CS-'); if (!rn || rn === 'RN-CS-') return;
        await nach(async () => {
          for (const p of a.posten) { const art = C.ARTIKEL[p.id]; if (!art) continue;
            for (let i = 0; i < p.n; i++) await rpc('credits_aufladen', { p_kunde: a.kunde, p_art: 'paket', p_credits: art.credits, p_rechnung: rn, p_notiz: art.name }); }
          await rpc('anfrage_status', { p_id: a.id, p_status: 'erledigt' });
        }, 'Ausgeführt. Credits sind gutgeschrieben.'); return;
      }
      if ('eanfrage' in d) {
        const ef = S.eform, k = S.kunden[S.kunde], p = C.eventPreis(ef, !!k.mitglied), E = C.EVENTS[ef.art], tag = S.form.tag;
        const text = `${E.name}, ${C.TAGE[tag]} ${ef.start}–${ef.start + p.dauer} Uhr, ${p.gaeste} Gäste, ca. ${C.eur(p.gesamt)}${ef.notiz ? ' · ' + ef.notiz : ''}`;
        const ok = await nach(() => rpc('anfrage_neu', { p_art: 'event', p_text: text, p_studio: 'lounge', p_daten: { datum: isoTag(tag), start: ef.start, ende: ef.start + p.dauer, camp: ef.camp || 0, eventArt: ef.art } }), 'Anfrage gesendet. Wir melden uns mit einem Angebot.');
        if (ok) { S.bModus = 'studio'; S.kTab = 'start'; C.render(); } return;
      }
      if (d.eventok) {
        const a = anfrage(d.eventok), kn = S.kunden[a.kunde]?.kn || '';
        await nach(async () => {
          await rpc('veranstaltung_eintragen', { p_start: zeitpunkt(a.tag, a.start), p_ende: zeitpunkt(a.tag, a.ende), p_titel: `${C.EVENTS[a.eventArt]?.name || 'Veranstaltung'} · ${kn}` });
          if (a.eventArt === 'camp' && a.camp) for (const r of a.camp === 2 ? ['s3', 's4'] : ['s3']) await rpc('blockieren', { p_studio: r, p_start: zeitpunkt(a.tag, a.start), p_ende: zeitpunkt(a.tag, a.ende), p_grund: `Songwriter Camp · ${kn}`, p_geschlossen: true }).catch(() => {});
          await rpc('anfrage_status', { p_id: a.id, p_status: 'erledigt' });
        }, 'Veranstaltung eingetragen.'); return;
      }
      if (d.merk) { S.merkliste[d.merk] = !S.merkliste[d.merk]; C.render(); if (S.merkliste[d.merk]) C.toast('Wir melden uns, sobald es verfügbar ist.'); return; }
      if ('export' in d) { exportCSV(); return; }
      C.toast('Diese Funktion ist in der App noch nicht freigeschaltet.');
    } finally { t.disabled = false; }
  }, true);

  // Eingaben: Notizen, Türcodes, Einstellungen
  const warte = {};
  const spaeter = (k, fn, ms = 700) => { clearTimeout(warte[k]); warte[k] = setTimeout(fn, ms); };
  document.addEventListener('input', (e) => {
    const t = e.target; if (!ICH) return;
    if (t.matches('[data-notiz]')) { const id = t.dataset.notiz, v = t.value; spaeter('n' + id, () => rpc('kunde_notiz', { p_kunde: id, p_notiz: v }).catch((x) => C.toast(fehlerText(x)))); }
    if (t.matches('[data-code]')) { const tag = +t.dataset.code, v = t.value.trim(); spaeter('c' + tag, () => rpc('tuercode_setzen', { p_tag: isoTag(tag), p_code: v }).catch((x) => C.toast(fehlerText(x)))); }
  }, true);
  document.addEventListener('change', async (e) => {
    const t = e.target; if (!ICH) return;
    if (t.matches('[data-sichtwahl],[data-kundewahl],[data-partnerwahl]')) { e.stopImmediatePropagation(); return; }
    if (t.matches('[data-einst],[data-einstbox]')) {
      e.stopImmediatePropagation();
      const k = t.dataset.einst || t.dataset.einstbox, v = t.dataset.einstbox ? t.checked : Math.max(0, +t.value || 0);
      if (k === 'partnerMax220') { const T = D.tarife.find((x) => x.id === 'PA 220'); await nach(() => rpc('tarif_speichern', { p_id: 'PA 220', p_name: T.name, p_art: T.art, p_credits: T.credits_monat, p_brutto: T.beitrag_brutto, p_nur: T.nur_studios, p_partner_max: v, p_einladung: T.nur_einladung, p_aktiv: true }), 'Gespeichert.'); return; }
      const key = { minHoerer: 's5_min_hoerer', minReleases: 's5_min_releases', ohneNoShow: 's5_ohne_noshow' }[k];
      if (key) await nach(() => rpc('einstellung_setzen', { p_schluessel: key, p_wert: v }), 'Gespeichert.');
    }
  }, true);

  // Formulare
  document.addEventListener('submit', async (e) => {
    const f = e.target;
    if (f.id === 'live-login') {
      e.preventDefault(); e.stopImmediatePropagation();
      const g = new FormData(f), msg = document.getElementById('live-msg'); msg.textContent = 'Einen Moment …';
      const { error } = await sb.auth.signInWithPassword({ email: String(g.get('mail')).trim(), password: String(g.get('pw')) });
      if (error) { msg.textContent = /invalid/i.test(error.message) ? 'E-Mail oder Passwort stimmt nicht.' : error.message; return; }
      await start(); return;
    }
    if (f.id === 'live-pw') {
      e.preventDefault(); e.stopImmediatePropagation();
      const g = new FormData(f), msg = document.getElementById('live-msg');
      if (g.get('pw') !== g.get('pw2')) { msg.textContent = 'Die Passwörter sind nicht gleich.'; return; }
      msg.style.color = '#A3A3A8'; msg.textContent = 'Einen Moment …';
      if (zugang) {
        await sb.auth.signOut().catch(() => {});
        const { error: ev } = await sb.auth.verifyOtp({ token_hash: zugang.token, type: zugang.typ });
        if (ev) { msg.style.color = '#FF8A8D'; msg.textContent = 'Dieser Link ist abgelaufen oder wurde schon benutzt. Bitte beim CloudStudios-Team einen neuen Link anfordern.'; return; }
      }
      const { error } = await sb.auth.updateUser({ password: String(g.get('pw')) });
      if (error) { msg.style.color = '#FF8A8D'; msg.textContent = /different|same/i.test(error.message) ? 'Bitte ein anderes Passwort wählen.' : /weak|short|least/i.test(error.message) ? 'Das Passwort ist zu schwach.' : error.message; return; }
      history.replaceState(null, '', location.pathname); await start(); return;
    }
    if (!ICH) return;
    e.preventDefault(); e.stopImmediatePropagation();
    const g = (k) => new FormData(f).get(k), knopf = f.querySelector('[type=submit]');
    if (knopf) knopf.disabled = true;
    try {
      if (f.id === 'f-intern') {
        const art = g('art'), studio = g('studio'), tag = +g('tag'), start = +g('start'), std = +g('std'), name = String(g('name') || '').trim();
        const msg = (text, gut) => C.meldung('f-intern-msg', text, gut);
        try {
          if (art === 'walkin') {
            if (!name) return msg('Bitte Namen eintragen.');
            const preis = String(g('preis') || '').replace(',', '.');
            await rpc('anfrage_eintragen', { p_studio: studio, p_start: zeitpunkt(tag, start), p_stunden: std, p_gast_name: name, p_kn: String(g('kn') || '').trim().toUpperCase() || null, p_preis_brutto: preis ? +preis : null, p_angebot: String(g('angebot') || '').trim() || null });
          } else if (art === 'credits') await rpc('credits_buchen', { p_studio: studio, p_start: zeitpunkt(tag, start), p_stunden: std, p_kunde: g('kunde') });
          else if (art === 'block') await rpc('blockieren', { p_studio: studio, p_start: zeitpunkt(tag, start), p_ende: zeitpunkt(tag, start + std), p_grund: name || 'Blockiert' });
          else await rpc('veranstaltung_eintragen', { p_start: zeitpunkt(tag, start), p_ende: zeitpunkt(tag, Math.min(24, start + std)), p_titel: name || 'Veranstaltung' });
          S.tag = tag; await laden(); msg('Eingetragen.', true);
        } catch (err) { msg(fehlerText(err), false); }
        return;
      }
      if (f.id === 'f-s5') {
        const fm = S.form, start = +g('start'), std = +g('std');
        await nach(() => rpc('bewerbung_senden', { p_start: zeitpunkt(fm.tag, start), p_stunden: std, p_kuenstler: String(g('kuenstler')).trim(), p_link: String(g('link')).trim(),
          p_hoerer: +g('hoerer'), p_releases: +g('releases'), p_label: String(g('label') || '').trim(), p_projekt: String(g('projekt')).trim(), p_engineer: !!g('engineer'), p_regeln: !!g('regeln') }), 'Bewerbung gesendet. BlackClouds entscheidet, wir melden uns.');
        return;
      }
      if (f.id === 'f-pauschale') {
        const name = String(g('name') || '').trim(), cr = +g('cr'), brutto = +g('brutto'), nur = ['s1', 's3', 's4', 's5'].filter((x) => g('nur_' + x)), art = g('art');
        if (!name || !cr || !brutto || !nur.length) return C.meldung('f-pauschale-msg', 'Name, Credits, Preis und mindestens ein Studio angeben.', false);
        const id = (name.match(/^(PA \d+)/) || [])[1] || name;
        await nach(() => rpc('tarif_speichern', { p_id: id, p_name: name.replace(id, '').trim() || name, p_art: art === 'basement' ? 'basement' : 'mitglied', p_credits: cr, p_brutto: brutto, p_nur: nur, p_einladung: !!g('einladung') }), `${name} angelegt.`);
        return;
      }
      if (f.id === 'f-brett') {
        const text = String(g('text') || '').trim(); if (!text) return;
        await nach(() => rpc('mitteilung_senden', { p_partner: f.dataset.partner, p_text: text }), f.dataset.von === 'CloudStudios' ? 'Gesendet.' : 'An CloudStudios gesendet.');
        return;
      }
      if (f.id === 'f-zustand') {
        const raum = g('raum'), text = String(g('text') || '').trim(), datei = g('foto');
        if (!text) return C.meldung('f-zustand-msg', 'Bitte kurz beschreiben, was los ist.', false);
        let pfad = null;
        if (datei && datei.size) {
          if (datei.size > 10 * 1024 * 1024) return C.meldung('f-zustand-msg', 'Das Foto ist zu groß (max. 10 MB).', false);
          pfad = `${ICH.partner || 'team'}/${Date.now()}-${(datei.name || 'foto.jpg').replace(/[^\w.-]/g, '_')}`;
          const { error } = await sb.storage.from('zustand').upload(pfad, datei, { contentType: datei.type || 'image/jpeg' });
          if (error) return C.meldung('f-zustand-msg', 'Foto konnte nicht hochgeladen werden: ' + error.message, false);
        }
        try { await rpc('zustand_melden', { p_raum: raum, p_text: text, p_foto: pfad }); S.zForm = { raum, text: '', foto: '' }; await laden(); C.meldung('f-zustand-msg', 'Gesendet. CloudStudios kümmert sich und meldet sich bei Ihnen.', true); }
        catch (err) { C.meldung('f-zustand-msg', fehlerText(err), false); }
        return;
      }
      if (f.id === 'f-partner') {
        const studio = g('studio'), tag = +g('tag'), von = +g('von'), bis = +g('bis');
        if (bis <= von) return C.meldung('f-partner-msg', 'Ende muss nach Beginn liegen.', false);
        try { await rpc('blockieren', { p_studio: studio, p_start: zeitpunkt(tag, von), p_ende: zeitpunkt(tag, bis), p_grund: 'Eigennutzung' }); S.pTag = tag; await laden(); C.meldung('f-partner-msg', 'Blockiert. Kunden sehen den Slot als belegt.', true); }
        catch (err) { C.meldung('f-partner-msg', fehlerText(err), false); }
        return;
      }
      if (f.id === 'f-konto') { await kontoAnlegen(f); return; }
      if (f.id === 'f-gutschein') { C.meldung('g-msg', 'Gutscheine werden aktuell über das Team eingelöst. Bitte Code per Nachricht schicken.', false); return; }
    } finally { if (knopf) knopf.disabled = false; }
  }, true);

  // Konto anlegen: Einladungslink über die Supabase-Funktion "einladen"
  async function kontoAnlegen(f) {
    const g = (k) => new FormData(f).get(k), a = S.kontoArt, msg = (t, ok) => { S.kontoMeldung = { t, ok }; C.meldung('f-konto-msg', t, ok); };
    const name = String(g('name') || '').trim(), mail = String(g('mail') || '').trim().toLowerCase(), tel = String(g('tel') || '').trim();
    if (!name || !mail) return msg('Name und E-Mail fehlen.', false);
    const kunde = ['paket', 'mitglied', 'basement', 'label'].includes(a);
    const kn = kunde ? (String(g('kn') || '').trim().toUpperCase() || naechsteKN()) : null;
    const body = { mail, name, tel: tel || null, kn, rolle: kunde ? 'kunde' : a, partner: a === 'partner' ? g('partner') : null, team_rolle: a === 'team' ? g('rolle') : null, redirect: location.origin + location.pathname };
    msg('Konto wird angelegt …', true);
    const { data, error } = await sb.functions.invoke('einladen', { body });
    if (error || !data?.id) { let t = error?.message || 'Unbekannter Fehler'; try { t = (await error.context.json()).fehler || t; } catch (_) {} C.toast('Konto nicht angelegt: ' + t); return msg('Nicht angelegt: ' + t, false); }
    const id = data.id; let info = '';
    try {
      if (a === 'paket') {
        const n = +g('paket'), rn = String(g('rn') || '').trim().toUpperCase(), bonus = Math.max(0, Math.min(10, +g('bonus') || 0));
        if (rn) { await rpc('credits_aufladen', { p_kunde: id, p_art: 'paket', p_credits: n, p_rechnung: rn }); info = `${n} Credits geladen`; } else info = `Paket ${n} wartet auf Zahlung`;
        if (bonus) await rpc('credits_aufladen', { p_kunde: id, p_art: 'bonus', p_credits: bonus, p_notiz: 'Willkommens-Bonus' });
      } else if (a === 'mitglied' || a === 'basement') {
        const tid = a === 'mitglied' ? g('tarif') : C.PTYPEN[+g('pauschale') || 0].id;
        const ab = g('beginn') === 'jetzt' ? isoTag(0) : isoTag(Math.round((Date.UTC(C.datum(0).getUTCFullYear(), C.datum(0).getUTCMonth() + 1, 1) - C.HEUTE) / 864e5));
        await rpc('mitgliedschaft_anlegen', { p_kunde: id, p_tarif: tid, p_ab: ab, p_vn: String(g('vn') || '').trim() || null });
        if (ab === isoTag(0)) await rpc('mitglieder_monatslauf', {});
        info = `${tid} ab ${deDatum(ab)}`;
      } else if (a === 'label') { const prod = (g('lrolle') || 'Artist') === 'Producer'; await rpc('mitgliedschaft_anlegen', { p_kunde: id, p_tarif: prod ? 'Label 60' : 'Label 30', p_ab: isoTag(0) }); try { await rpc('mitglieder_monatslauf', {}); } catch (_) {} info = (prod ? 60 : 30) + ' Label-Credits je Monat'; }
      if (kunde && g('s5')) await rpc('freigabe_setzen', { p_kunde: id, p_an: true, p_studio: 's5' });
      if (kunde && g('notiz')) await rpc('kunde_notiz', { p_kunde: id, p_notiz: String(g('notiz')) });
    } catch (err) { info += ' · Achtung: ' + fehlerText(err); }
    S.einladung = { name, mail, tel, link: data.link, ansicht: kunde ? 'Kunden-App' : a === 'partner' ? 'Partner-Ansicht' : 'Team-Ansicht' };
    await laden();
    msg(`${kn ? kn + ' ' : ''}${name} angelegt${info ? ' · ' + info : ''}. Link unten per WhatsApp schicken.`, true);
  }
  function naechsteKN() {
    const n = Math.max(0, ...Object.values(S.kunden).map((k) => +(String(k.kn).match(/(\d+)/) || [0, 0])[1]));
    return 'KN - ' + String(n + 1).padStart(3, '0');
  }

  function exportCSV() {
    const z = [['Datum', 'Beginn', 'Ende', 'Raum', 'Status', 'Kunde/Gast', 'KN', 'Credits', 'Preis brutto', 'Rechnung']];
    for (const b of S.buchungen) z.push([C.TAGE[b.tag] || b.tag, b.von, b.bis, C.ST[b.studio]?.name, b.status, b.kunde ? S.kunden[b.kunde]?.name : b.gast || b.grund || '', b.kunde ? S.kunden[b.kunde]?.kn : b.kn || '', b.credits, b.preis ?? '', b.rechnung || '']);
    const csv = '﻿' + z.map((r) => r.map((v) => `"${String(v ?? '').replace(/"/g, '""')}"`).join(';')).join('\n');
    const a = document.createElement('a'); a.href = URL.createObjectURL(new Blob([csv], { type: 'text/csv' })); a.download = `CloudStudios_Buchungen_${isoTag(0)}.csv`; a.click();
  }

  // ---------- Start ----------
  async function start() {
    const { data: { session } } = await sb.auth.getSession();
    if (zugang && !start._pwGesetzt) { start._pwGesetzt = true; ICH = null; leiste(); return passwortSeite(); }
    if (linkFehler && !session) { history.replaceState(null, '', location.pathname); ICH = null; leiste(); return anmeldeSeite('Dieser Link ist abgelaufen oder wurde schon benutzt. Bitte beim CloudStudios-Team einen neuen Link anfordern.'); }
    if (!session) { ICH = null; leiste(); return anmeldeSeite(); }
    if (linkTyp && !start._pwGesetzt) { start._pwGesetzt = true; ICH = null; return passwortSeite(); }
    try { await laden(); }
    catch (e) {
      if (/NICHT_ANGEMELDET|JWT|token/i.test(e.message || '')) { await sb.auth.signOut(); return anmeldeSeite('Ihr Konto ist gesperrt oder abgelaufen. Bitte beim Team melden.'); }
      app.innerHTML = `<div class="karte fehler" style="margin:10vh auto;max-width:400px">Die Daten konnten nicht geladen werden: ${C.esc(fehlerText(e))}<br><button onclick="location.reload()" style="margin-top:10px">Neu laden</button></div>`;
    }
  }
  sb.auth.onAuthStateChange((ev) => { if (ev === 'SIGNED_OUT') { ICH = null; anmeldeSeite(); } });
  // Daten frisch halten: bei Rückkehr in die App und alle 60 Sekunden
  const amTippen = () => document.activeElement?.matches('input,textarea,select') ||
    [...document.querySelectorAll('form input:not([type=checkbox]):not([type=hidden]), form textarea')].some((i) => i.value && i.defaultValue !== i.value);
  document.addEventListener('visibilitychange', () => { if (!document.hidden && ICH && !amTippen()) laden().catch(() => {}); });
  setInterval(() => { if (!document.hidden && ICH && !amTippen()) laden().catch(() => {}); }, 60000);
  // Zugangslink in einem schon offenen Tab: Safari wechselt dann nur den #-Teil und lädt nicht neu
  window.addEventListener('hashchange', () => { if (/zugang=/.test(location.hash)) location.reload(); });
  start();
})();
