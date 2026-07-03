const C="kux-v1";
const A=["./","index.html","app.html","validar.html","logo.png","hero.jpg","icon-192.png","icon-512.png","manifest.webmanifest"];
self.addEventListener("install",e=>{e.waitUntil(caches.open(C).then(c=>c.addAll(A)).catch(()=>{}));self.skipWaiting();});
self.addEventListener("activate",e=>{e.waitUntil(caches.keys().then(k=>Promise.all(k.filter(x=>x!==C).map(x=>caches.delete(x)))));self.clients.claim();});
self.addEventListener("fetch",e=>{
  const u=new URL(e.request.url);
  if(u.origin!==location.origin) return;                 // Supabase/CDN: directo a la red, nunca cache
  if(e.request.mode==="navigate"||u.pathname.endsWith(".html")){
    e.respondWith(fetch(e.request).catch(()=>caches.match(e.request).then(r=>r||caches.match("index.html"))));
    return;
  }
  e.respondWith(caches.match(e.request).then(r=>r||fetch(e.request)));
});