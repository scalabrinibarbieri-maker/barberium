// Barberium v12.4 — Web Push. A permissão só é solicitada por um clique do cliente.
export function createPushUI({rpc,getSession,shopSlug,toast}) {
  let config=null, registration=null, subscription=null, active=false, busy=false, initialized=false;
  const supported=()=>window.isSecureContext && 'serviceWorker' in navigator && 'PushManager' in window && 'Notification' in window;
  const ios=()=>/iPad|iPhone|iPod/.test(navigator.userAgent)||(navigator.platform==='MacIntel'&&navigator.maxTouchPoints>1);
  const standalone=()=>matchMedia('(display-mode: standalone)').matches||navigator.standalone===true;
  const args=()=>({p_barbershop_slug:shopSlug,p_access_token:getSession()?.access_token||''});
  const escape=s=>String(s).replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
  function markup(mode='invite') {
    if(!getSession()?.access_token)return '';
    if(mode==='invite' && (active||sessionStorage.getItem('barberium-push-later')))return '';
    let text='Ative as notificações para receber lembretes dos seus horários!';
    let hint='Receba confirmações, alterações e lembretes 24 horas e 2 horas antes, neste aparelho. Você pode desativar quando quiser.';
    let buttons='';
    if(ios()&&!standalone()) {
      hint='No iPhone ou iPad, abra este site no Safari, toque em Compartilhar → Adicionar à Tela de Início. Depois abra pelo ícone e ative as notificações.';
    } else if(!supported()) {
      hint='Este navegador não oferece notificações push aqui. Tente abrir o Barberium em um navegador compatível, fora da navegação privada.';
    } else if(Notification.permission==='denied') {
      text='As notificações estão bloqueadas neste navegador.';
      hint='Para ativar, abra as permissões deste site nas configurações do navegador e permita notificações. Depois volte aqui.';
    } else if(active) {
      text='Lembretes ativados neste aparelho';hint='Você receberá avisos dos seus horários. A entrega depende da conexão e das configurações do celular.';
      buttons='<button class="secondary-button" data-push="test" type="button">Testar notificação</button><button class="secondary-button" data-push="disable" type="button">Desativar neste aparelho</button>';
    } else if(!initialized) {hint='Preparando as notificações…';}
    else if(!config?.enabled) {hint='As notificações estão temporariamente indisponíveis. Tente novamente mais tarde.';}
    else buttons='<button class="gold-button" data-push="enable" type="button">Ativar notificações</button>';
    if(mode==='invite')buttons+='<button class="push-later" data-push="later" type="button">Agora não</button>';
    return `<section class="push-card" data-push-card="${mode}"><span class="kicker">Lembretes no celular</span><h3>${escape(text)}</h3><p>${escape(hint)}</p><div class="push-actions">${buttons}</div><p class="push-feedback" role="status" aria-live="polite"></p></section>`;
  }
  function render() {
    document.querySelectorAll('[data-push-mount]').forEach(el=>el.innerHTML=markup(el.dataset.pushMount));
  }
  function feedback(text) {document.querySelectorAll('.push-feedback').forEach(el=>el.textContent=text);}
  async function init() {
    try {
      config=await rpc('barberium_push_public_config');
      if(supported()) {
        registration=await navigator.serviceWorker.register('./sw.js?v=12.4',{updateViaCache:'none'});
        if(!registration.active) await Promise.race([navigator.serviceWorker.ready,new Promise((_,reject)=>setTimeout(()=>reject(new Error('O navegador ainda está preparando as notificações. Tente novamente.')),12000))]);
        subscription=await registration.pushManager.getSubscription();
        if(subscription&&getSession()?.access_token) {
          const result=await rpc('barberium_push_device',{...args(),p_endpoint:subscription.endpoint,p_action:'status'});
          active=result.enabled&&Notification.permission==='granted';
          if(result.enabled&&Notification.permission==='denied') await rpc('barberium_push_device',{...args(),p_endpoint:subscription.endpoint,p_action:'disable'});
        }
      }
    } catch {config=null;}
    initialized=true;render();
  }
  function decodeKey(value) {return Uint8Array.from(atob(value.replace(/-/g,'+').replace(/_/g,'/').padEnd(Math.ceil(value.length/4)*4,'=')),c=>c.charCodeAt(0));}
  async function action(name) {
    if(name==='later'){sessionStorage.setItem('barberium-push-later','1');render();return;}
    if(busy)return;
    busy=true;document.querySelectorAll('[data-push]').forEach(b=>b.disabled=true);
    let message='';
    try {
      if(name==='enable') {
        if(!supported()||!config?.enabled||!registration)throw new Error('As notificações ainda não estão prontas. Atualize a página e tente novamente.');
        // Primeiro await é o pedido de permissão, preservando a interação exigida no iOS.
        const permission=await Notification.requestPermission();
        if(permission!=='granted'){message=permission==='denied'?'Permissão bloqueada. Você pode mudar isso nas configurações do navegador.':'Você pode ativar mais tarde em Meu perfil.';return;}
        subscription=await registration.pushManager.getSubscription();
        if(!subscription)subscription=await registration.pushManager.subscribe({userVisibleOnly:true,applicationServerKey:decodeKey(config.public_key)});
        await rpc('barberium_push_subscribe',{...args(),p_subscription:subscription.toJSON()});
        active=true;message='Notificações ativadas! Uma mensagem de confirmação chegará em instantes.';
      } else if(name==='disable'&&subscription) {
        await rpc('barberium_push_device',{...args(),p_endpoint:subscription.endpoint,p_action:'disable'});
        active=false;await subscription.unsubscribe();subscription=null;message='Notificações desativadas neste aparelho.';
      } else if(name==='test'&&subscription) {
        await rpc('barberium_push_device',{...args(),p_endpoint:subscription.endpoint,p_action:'test'});
        message='Teste solicitado. A notificação deve chegar em até alguns minutos.';
      }
    } catch(e) {message=e.message||'Não foi possível concluir. Tente novamente.';}
    finally {busy=false;render();feedback(message);if(message)toast(message);}
  }
  document.addEventListener('click',e=>{const button=e.target.closest('[data-push]');if(button)action(button.dataset.push);});
  return {init,render,mount:(mode='invite')=>`<div data-push-mount="${mode}">${markup(mode)}</div>`};
}
