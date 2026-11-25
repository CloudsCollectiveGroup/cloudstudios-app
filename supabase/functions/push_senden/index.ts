// CloudStudios · Push-Versand
// Holt offene Einträge aus push_warteschlange und verschickt sie an alle Geräte des Nutzers.
// Aufruf: sofort nach jedem neuen Eintrag (Datenbank) und alle 5 Minuten (Zeitplan).
// JWT-Prüfung ist aus: Die Funktion tut nichts außer die Warteschlange abzuarbeiten.
// Das VAPID-Schlüsselpaar erzeugt sie beim ersten Lauf selbst (Tabelle push_schluessel).
import { createClient } from "npm:@supabase/supabase-js@2";
import webpush from "npm:web-push@3.6.7";


function serviceKey(): string {
  const direkt = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (direkt) return direkt;
  const liste = Deno.env.get("SUPABASE_SECRET_KEYS");
  if (liste) { try { const o = JSON.parse(liste); const v = Object.values(o)[0]; if (typeof v === "string") return v; } catch (_) { /* weiter */ } }
  return Deno.env.get("SUPABASE_SECRET_KEY") ?? "";
}

Deno.serve(async () => {
  const db = createClient(Deno.env.get("SUPABASE_URL")!, serviceKey(), { auth: { persistSession: false } });
  // Schlüsselpaar holen bzw. beim ersten Lauf erzeugen (bleibt danach unverändert)
  let { data: k } = await db.from("push_schluessel").select("oeffentlich, privat").eq("id", 1).maybeSingle();
  if (!k) {
    const neu = webpush.generateVAPIDKeys();
    await db.from("push_schluessel").upsert({ id: 1, oeffentlich: neu.publicKey, privat: neu.privateKey }, { onConflict: "id", ignoreDuplicates: true });
    ({ data: k } = await db.from("push_schluessel").select("oeffentlich, privat").eq("id", 1).maybeSingle());
  }
  if (!k) return new Response(JSON.stringify({ fehler: "Schlüssel fehlen" }), { status: 500 });
  webpush.setVapidDetails("mailto:management@cloudstudioshh.de", k.oeffentlich, k.privat);

  const { data: offen, error } = await db.rpc("push_holen", { p_max: 200 });
  if (error) return new Response(JSON.stringify({ fehler: error.message }), { status: 500 });
  let gesendet = 0, entfernt = 0;
  for (const m of offen ?? []) {
    const { data: abos } = await db.from("push_abos").select("id, endpoint, p256dh, auth").eq("nutzer", m.nutzer);
    let ok = 0;
    for (const a of abos ?? []) {
      try {
        await webpush.sendNotification({ endpoint: a.endpoint, keys: { p256dh: a.p256dh, auth: a.auth } },
          JSON.stringify({ titel: m.titel, text: m.text, url: m.url ?? "./", art: m.art }), { TTL: 86400, urgency: "high" });
        ok++; gesendet++;
      } catch (e) {
        const code = (e as { statusCode?: number }).statusCode;
        if (code === 404 || code === 410) { await db.from("push_abos").delete().eq("id", a.id); entfernt++; }
      }
    }
    await db.from("push_warteschlange").update({ ergebnis: `${ok}/${abos?.length ?? 0}` }).eq("id", m.id);
  }
  return new Response(JSON.stringify({ eintraege: offen?.length ?? 0, gesendet, entfernt }), { headers: { "Content-Type": "application/json" } });
});
