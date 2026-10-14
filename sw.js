// GiocoLegami: salva la pagina sul telefono così si apre subito; i dati dei giochi arrivano sempre dalla rete.
const V = "giocolegami-v2";
const SHELL = ["./", "index.html", "manifest.webmanifest", "icon-192.png", "icon-512.png", "apple-touch-icon.png"];

self.addEventListener("install", (e) => {
  e.waitUntil(caches.open(V).then((c) => c.addAll(SHELL)).then(() => self.skipWaiting()));
});

self.addEventListener("activate", (e) => {
  e.waitUntil(
    caches.keys().then((ks) => Promise.all(ks.filter((k) => !k.startsWith(V)).map((k) => caches.delete(k)))).then(() => self.clients.claim())
  );
});

self.addEventListener("fetch", (e) => {
  const r = e.request;
  if (r.method !== "GET") return;
  const u = new URL(r.url);
  if (u.origin === location.origin) {
    // pagina e icone: prima la rete (così gli aggiornamenti arrivano), se manca la rete usa la copia salvata
    e.respondWith(
      fetch(r).then((res) => {
        if (res.ok) { const copy = res.clone(); caches.open(V).then((c) => c.put(r, copy)); }
        return res;
      }).catch(() => caches.match(r).then((m) => m || caches.match("index.html")))
    );
  } else if (u.hostname === "images.igdb.com") {
    // copertine e loghi: copia salvata se c'è
    e.respondWith(
      caches.open(V + "-img").then((c) =>
        c.match(r).then((m) => m || fetch(r).then((res) => { if (res.ok || res.type === "opaque") c.put(r, res.clone()); return res; }))
      )
    );
  }
});
