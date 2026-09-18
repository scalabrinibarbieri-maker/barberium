const CACHE='scalabrini-client-v12-15';
const PRECACHE=[
  './','./index.html','./styles.css?v=12.4','./desktop-v12.15.css?v=12.15','./app.js?v=12.7.1','./push.js?v=12.4','./membership.css?v=11.2','./membership.js?v=11.2','./site.webmanifest','./equipe/','./equipe/index.html','./equipe/team.css?v=12.3.1','./equipe/settings.css?v=12','./equipe/team.js?v=12.7','./equipe/agenda-cancelados-v12.8.js?v=12.8','./equipe/finance-reports.js?v=12.8.1','./equipe/settings.js?v=12.7.1','./equipe/barberium-v12.9.js?v=12.9','./equipe/barberium-v12.10.js?v=12.10','./equipe/barberium-v12.13.js?v=12.13',
  './assets/corte-barba-sobrancelha.webp','./assets/combo-corte-barba.webp','./assets/combo-corte-barboterapia.webp',
  './assets/barba-express.webp','./assets/barba-tradizionale.webp','./assets/pezinho-detalhes.webp','./assets/sobrancelha.webp',
  './assets/vinicius-nunes.webp','./assets/barboterapia.webp','./assets/logo-sb.webp','./assets/cabeca-raspada.webp',
  './assets/barbearia.webp','./assets/jean-dalarmi.webp','./assets/corte-barba-express.webp','./assets/corte.webp'
];
self.addEventListener('install',event=>{event.waitUntil(caches.open(CACHE).then(cache=>cache.addAll(PRECACHE)));self.skipWaiting()});
self.addEventListener('activate',event=>{event.waitUntil(caches.keys().then(keys=>Promise.all(keys.filter(key=>key!==CACHE).map(key=>caches.delete(key)))));self.clients.claim()});
async function networkFirst(request){try{const response=await fetch(request,{cache:'no-store'});if(response&&response.ok){const cache=await caches.open(CACHE);cache.put(request,response.clone())}return response}catch(error){const cached=await caches.match(request,{ignoreSearch:false});if(cached)return cached;throw error}}
self.addEventListener('fetch',event=>{if(event.request.method!=='GET')return;if(event.request.mode==='navigate'){event.respondWith(networkFirst(event.request).catch(()=>new URL(event.request.url).pathname.includes('/equipe')?caches.match('./equipe/index.html'):caches.match('./index.html')));return}const dest=event.request.destination;if(dest==='script'||dest==='style'){event.respondWith(networkFirst(event.request));return}event.respondWith(caches.match(event.request).then(cached=>cached||fetch(event.request).then(response=>{if(response&&response.ok){const copy=response.clone();caches.open(CACHE).then(cache=>cache.put(event.request,copy))}return response})))});

// v12.4: a entrega é feita pelo servidor; não depende de timers na página.
self.addEventListener('push',event=>event.waitUntil((async()=>{
 let data={};try{data=event.data?.json()||{}}catch{}
 if(data.expires_at && Date.parse(data.expires_at)<Date.now())return;
 await self.registration.showNotification(data.title||'Barberium',{
  body:data.body||'Confira seus agendamentos.',icon:new URL('./assets/logo-sb.webp',self.registration.scope).href,
  tag:data.tag||'barberium',renotify:false,data:{url:data.audience==='staff'?(/^[0-9a-f-]{36}$/i.test(data.appointment_id||'')?'equipe/?appointment='+data.appointment_id:'equipe/?whatsapp=1'):'?view=appointments'},
 });
})()));
self.addEventListener('notificationclick',event=>{
 event.notification.close();event.waitUntil((async()=>{
  const route=event.notification.data?.url||'';
  const staff=route==='equipe/?whatsapp=1'||/^equipe\/\?appointment=[0-9a-f-]{36}$/i.test(route);
  const target=new URL(staff?'./'+route:'./?view=appointments',self.registration.scope).href;
  const tabs=await self.clients.matchAll({type:'window',includeUncontrolled:true});
  for(const tab of tabs){if(tab.url.startsWith(self.registration.scope)&&new URL(tab.url).pathname.includes('/equipe')===staff){await tab.navigate(target);await tab.focus();return;}}
  await self.clients.openWindow(target);
 })());
});
