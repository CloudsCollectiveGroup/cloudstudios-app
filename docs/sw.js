// CloudStudios · Service Worker (nur für Push-Mitteilungen, kein Offline-Cache)
self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', (e) => e.waitUntil(self.clients.claim()));
self.addEventListener('push', (e) => {
  let d = {};
  try { d = e.data ? e.data.json() : {}; } catch (_) { d = { titel: 'CloudStudios', text: e.data ? e.data.text() : '' }; }
  e.waitUntil(self.registration.showNotification(d.titel || 'CloudStudios', {
    body: d.text || '', icon: 'bilder/icon-192.png', badge: 'bilder/icon-192.png',
    tag: d.art ? 'cs-' + d.art + '-' + Date.now() : undefined, data: { url: d.url || './' }
  }));
});
self.addEventListener('notificationclick', (e) => {
  e.notification.close();
  const ziel = new URL(e.notification.data?.url || './', self.registration.scope).href;
  e.waitUntil((async () => {
    const offen = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
    for (const c of offen) { if (c.url.startsWith(self.registration.scope)) { await c.focus(); return; } }
    await self.clients.openWindow(ziel);
  })());
});
