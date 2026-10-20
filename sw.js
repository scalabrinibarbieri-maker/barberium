// Service worker do Barberium: um só para o site do cliente e para a Área da Equipe.
//
// Etapa 4 (20/10/2026). A versão abaixo é carimbada a cada publicação por deploy/montar_site.sh
// (é o commit publicado). Cada versão tem um cache próprio, e quando ela assume, os caches das
// versões anteriores são apagados. Assim nenhum celular fica preso numa versão antiga.
//
// O que fica guardado no aparelho:
//   páginas, scripts e estilos: vêm sempre da internet; a cópia guardada só é usada sem internet;
//   imagens do próprio site: guardadas na primeira vez que aparecem, até a próxima versão;
//   o resto (Supabase, fotos enviadas pela equipe, bibliotecas externas) não passa por aqui.
// Só é guardado o que veio do tipo certo: se um arquivo sumir e o servidor devolver a página
// inicial no lugar dele, isso não vai para o cache.
const VERSAO='__VERSAO__';
const CACHE='barberium-'+VERSAO;
const PAGINAS=['./','./equipe/'];
const TIPOS={document:/text\/html/i,script:/javascript/i,style:/text\/css/i,image:/^image\//i};

function podeGuardar(resposta,tipo){
  return !!(resposta&&resposta.ok&&resposta.type==='basic'&&TIPOS[tipo]&&TIPOS[tipo].test(resposta.headers.get('content-type')||''));
}
async function guardar(pedido,resposta,tipo){
  if(!podeGuardar(resposta,tipo))return;
  const cache=await caches.open(CACHE);
  await cache.put(pedido,resposta);
}
async function daRedePrimeiro(pedido,tipo){
  try{
    const resposta=await fetch(pedido,{cache:'no-store'});
    if(podeGuardar(resposta,tipo))guardar(pedido,resposta.clone(),tipo).catch(()=>{});
    return resposta;
  }catch(erro){
    const guardada=await caches.match(pedido);
    if(guardada)return guardada;
    throw erro;
  }
}
async function guardadoPrimeiro(pedido,tipo){
  const guardada=await caches.match(pedido);
  if(guardada)return guardada;
  const resposta=await fetch(pedido);
  if(podeGuardar(resposta,tipo))guardar(pedido,resposta.clone(),tipo).catch(()=>{});
  return resposta;
}
async function paginaGuardada(url){
  const pagina=new URL(url.pathname.includes('/equipe')?'./equipe/':'./',self.registration.scope).href;
  return (await caches.match(pagina))||Response.error();
}

self.addEventListener('install',event=>{
  // Pré-cache mínimo: só as duas páginas, para abrir sem internet. Se falhar, instala assim mesmo.
  event.waitUntil(Promise.allSettled(PAGINAS.map(async p=>{
    const pedido=new Request(new URL(p,self.registration.scope).href);
    await guardar(pedido,await fetch(pedido,{cache:'no-store'}),'document');
  })));
  self.skipWaiting();
});
self.addEventListener('activate',event=>{
  event.waitUntil(caches.keys().then(nomes=>Promise.all(nomes.filter(n=>n!==CACHE).map(n=>caches.delete(n)))).then(()=>self.clients.claim()));
});
self.addEventListener('fetch',event=>{
  const pedido=event.request;
  if(pedido.method!=='GET')return;
  const url=new URL(pedido.url);
  if(url.origin!==self.location.origin)return;
  if(url.pathname.endsWith('/versao.json')||url.pathname.endsWith('/sw.js'))return;
  if(pedido.mode==='navigate'){event.respondWith(daRedePrimeiro(pedido,'document').catch(()=>paginaGuardada(url)));return}
  const tipo=pedido.destination;
  if(tipo==='script'||tipo==='style'){event.respondWith(daRedePrimeiro(pedido,tipo));return}
  if(tipo==='image'){event.respondWith(guardadoPrimeiro(pedido,tipo));return}
});

// Notificações (iguais às de antes da etapa 4).
self.addEventListener('push',event=>event.waitUntil((async()=>{let data={};try{data=event.data?.json()||{}}catch{}if(data.expires_at&&Date.parse(data.expires_at)<Date.now())return;await self.registration.showNotification(data.title||'Barberium',{body:data.body||'Confira seus agendamentos.',icon:new URL('./assets/logo-sb.webp',self.registration.scope).href,tag:data.tag||'barberium',renotify:false,data:{url:data.audience==='staff'?(/^[0-9a-f-]{36}$/i.test(data.appointment_id||'')?'equipe/?appointment='+data.appointment_id:'equipe/?whatsapp=1'):'?view=appointments'}})})()));
self.addEventListener('notificationclick',event=>{event.notification.close();event.waitUntil((async()=>{const route=event.notification.data?.url||'';const staff=route==='equipe/?whatsapp=1'||/^equipe\/\?appointment=[0-9a-f-]{36}$/i.test(route);const target=new URL(staff?'./'+route:'./?view=appointments',self.registration.scope).href;const tabs=await self.clients.matchAll({type:'window',includeUncontrolled:true});for(const tab of tabs){if(tab.url.startsWith(self.registration.scope)&&new URL(tab.url).pathname.includes('/equipe')===staff){await tab.navigate(target);await tab.focus();return}}await self.clients.openWindow(target)})())});
