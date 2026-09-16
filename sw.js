const CACHE='scalabrini-client-v11';
const PRECACHE=[
  './','./index.html','./styles.css?v=7','./app.js?v=7','./membership.css?v=11','./membership.js?v=11','./site.webmanifest','./equipe/','./equipe/index.html','./equipe/team.css?v=11','./equipe/team.js?v=11',
  './assets/corte-barba-sobrancelha.webp','./assets/combo-corte-barba.webp','./assets/combo-corte-barboterapia.webp',
  './assets/barba-express.webp','./assets/barba-tradizionale.webp','./assets/pezinho-detalhes.webp','./assets/sobrancelha.webp',
  './assets/vinicius-nunes.webp','./assets/barboterapia.webp','./assets/logo-sb.webp','./assets/cabeca-raspada.webp',
  './assets/barbearia.webp','./assets/jean-dalarmi.webp','./assets/corte-barba-express.webp','./assets/corte.webp'
];
self.addEventListener('install',event=>{event.waitUntil(caches.open(CACHE).then(cache=>cache.addAll(PRECACHE)));self.skipWaiting()});
self.addEventListener('activate',event=>{event.waitUntil(caches.keys().then(keys=>Promise.all(keys.filter(key=>key!==CACHE).map(key=>caches.delete(key)))));self.clients.claim()});
async function networkFirst(request){try{const response=await fetch(request,{cache:'no-store'});if(response&&response.ok){const cache=await caches.open(CACHE);cache.put(request,response.clone())}return response}catch(error){const cached=await caches.match(request,{ignoreSearch:false});if(cached)return cached;throw error}}
self.addEventListener('fetch',event=>{if(event.request.method!=='GET')return;if(event.request.mode==='navigate'){event.respondWith(networkFirst(event.request).catch(()=>new URL(event.request.url).pathname.includes('/equipe')?caches.match('./equipe/index.html'):caches.match('./index.html')));return}const dest=event.request.destination;if(dest==='script'||dest==='style'){event.respondWith(networkFirst(event.request));return}event.respondWith(caches.match(event.request).then(cached=>cached||fetch(event.request).then(response=>{if(response&&response.ok){const copy=response.clone();caches.open(CACHE).then(cache=>cache.put(event.request,copy))}return response})))});
