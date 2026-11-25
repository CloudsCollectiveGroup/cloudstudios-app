// CloudStudios · Supabase-Funktion "einladen"
// Legt ein Konto an und gibt einen persönlichen Einladungslink zurück (Versand per WhatsApp durch das Team).
// Nur für angemeldete Personen mit dem Recht "konten". Team- und Partner-Konten nur durch den Admin.
// Mit {"neuer_link": true} gibt es für ein bestehendes Konto einen Link zum Passwort-Zurücksetzen.
import { createClient } from 'npm:@supabase/supabase-js@2';

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
// Eigener App-Link statt des Supabase-Links: Link-Vorschauen (WhatsApp, iMessage) öffnen sonst den Einmal-Link
// und verbrauchen ihn. Der Code steht hinter dem #, wird nie an einen Server geschickt und erst beim Speichern eingelöst.
const appLink = (basis: string, token: string, typ: string) => `${basis || ''}#zugang=${encodeURIComponent(token)}&typ=${typ}`;
const antwort = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...CORS, 'Content-Type': 'application/json' } });

function geheimerSchluessel(): string {
  const alt = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  if (alt) return alt;
  const neu = Deno.env.get('SUPABASE_SECRET_KEYS');
  if (neu) { try { const j = JSON.parse(neu); return j.default ?? Object.values(j)[0] as string; } catch { return neu; } }
  return Deno.env.get('SUPABASE_SECRET_KEY') ?? '';
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  try {
    const admin = createClient(Deno.env.get('SUPABASE_URL')!, geheimerSchluessel(), { auth: { persistSession: false } });
    const jwt = (req.headers.get('Authorization') ?? '').replace(/^Bearer\s+/i, '');
    const { data: wer } = await admin.auth.getUser(jwt);
    if (!wer?.user) return antwort({ fehler: 'Bitte neu anmelden.' }, 401);
    const { data: ich } = await admin.from('profiles').select('rolle, team_rolle, aktiv').eq('id', wer.user.id).single();
    let darf = !!ich?.aktiv && ich.rolle === 'admin';
    if (!darf && ich?.aktiv && ich.rolle === 'team') {
      const { data: r } = await admin.from('rollen_rechte').select('recht').eq('rolle', ich.team_rolle ?? 'buchung').eq('recht', 'konten');
      darf = !!r?.length;
    }
    if (!darf) return antwort({ fehler: 'Keine Berechtigung für Konten.' }, 403);

    const b = await req.json();
    const mail = String(b.mail ?? '').trim().toLowerCase();
    if (!mail.includes('@')) return antwort({ fehler: 'E-Mail fehlt.' }, 400);

    if (b.neuer_link) {
      const { data, error } = await admin.auth.admin.generateLink({ type: 'recovery', email: mail, options: { redirectTo: b.redirect || undefined } });
      if (error) return antwort({ fehler: error.message }, 400);
      await admin.from('protokoll').insert({ von: wer.user.id, aktion: 'neuer_link', details: { konto: data.user.id } });
      return antwort({ id: data.user.id, link: appLink(b.redirect, data.properties.hashed_token, 'recovery') });
    }

    const name = String(b.name ?? '').trim();
    const rolle = ['kunde', 'team', 'partner'].includes(b.rolle) ? b.rolle : 'kunde';
    if (!name) return antwort({ fehler: 'Name fehlt.' }, 400);
    if (rolle !== 'kunde' && ich!.rolle !== 'admin') return antwort({ fehler: 'Team- und Partner-Konten legt nur der Admin an.' }, 403);
    if (rolle === 'partner' && !['basement', 'blackclouds'].includes(b.partner)) return antwort({ fehler: 'Partner fehlt.' }, 400);

    const { data, error } = await admin.auth.admin.generateLink({
      type: 'invite', email: mail,
      options: { data: { name, kn: b.kn ?? '' }, redirectTo: b.redirect || undefined },
    });
    if (error) return antwort({ fehler: /already|registered|exists/i.test(error.message) ? 'Diese E-Mail hat schon ein Konto.' : error.message }, 400);
    const id = data.user.id;
    const { error: e2 } = await admin.from('profiles').update({
      name, kn: rolle === 'kunde' ? (b.kn || null) : null, telefon: b.tel || null, rolle,
      partner: rolle === 'partner' ? b.partner : null,
      team_rolle: rolle === 'team' ? (b.team_rolle || 'buchung') : 'buchung',
    }).eq('id', id);
    if (e2) {
      await admin.auth.admin.deleteUser(id);
      return antwort({ fehler: /kn/.test(e2.message) ? 'Diese Kundennummer ist schon vergeben.' : e2.message }, 400);
    }
    await admin.from('protokoll').insert({ von: wer.user.id, aktion: 'konto_anlegen', details: { konto: id, rolle, kn: b.kn ?? null } });
    return antwort({ id, link: appLink(b.redirect, data.properties.hashed_token, 'invite') });
  } catch (e) {
    return antwort({ fehler: String((e as Error)?.message ?? e) }, 500);
  }
});
