const CACHE='scalabrini-client-v4';
const ASSETS=["./", "./index.html", "./styles.css", "./app.js", "./site.webmanifest", "./assets/corte-barba-sobrancelha.webp", "./assets/combo-corte-barba.webp", "./assets/combo-corte-barboterapia.webp", "./assets/barba-express.webp", "./assets/barba-tradizionale.webp", "./assets/pezinho-detalhes.webp", "./assets/sobrancelha.webp", "./assets/vinicius-nunes.webp", "./assets/barboterapia.webp", "./assets/logo-sb.webp", "./assets/cabeca-raspada.webp", "./assets/barbearia.webp", "./assets/jean-dalarmi.webp", "./assets/corte-barba-express.webp", "./assets/corte.webp"];
self.addEventListener('install',e=>{e.waitUntil(caches.open(CACHE).then(c=>c.addAll(ASSETS)));self.skipWaiting();});
self.addEventListener('activate',e=>{e.waitUntil(caches.keys().then(keys=>Promise.all(keys.filter(k=>k!==CACHE).map(k=>caches.delete(k)))));self.clients.claim();});
self.addEventListener('fetch',e=>{
  if(e.request.method!=='GET')return;
  if(e.request.mode==='navigate'){
    e.respondWith(fetch(e.request).then(r=>{const c=r.clone();caches.open(CACHE).then(x=>x.put(e.request,c));return r;}).catch(()=>caches.match('./index.html')));
    return;
  }
  e.respondWith(caches.match(e.request).then(cached=>cached||fetch(e.request).then(r=>{const c=r.clone();caches.open(CACHE).then(x=>x.put(e.request,c));return r;})));
});
