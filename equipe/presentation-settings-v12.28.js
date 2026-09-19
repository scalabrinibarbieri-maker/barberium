/* Barberium v12.28 · apresentação personalizável da página inicial */
(() => {
  const SUPABASE_URL='https://pmvvawbaqylspxfmxezw.supabase.co';
  const SUPABASE_KEY='sb_publishable_CveglntZGjChE89lPcsQcg_EvBnYmKo';
  const AUTH_KEY='barberium_staff_auth_v1';
  const $=(s,r=document)=>r.querySelector(s);
  const esc=(v='')=>String(v??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#039;'}[c]));

  function session(){try{return JSON.parse(localStorage.getItem(AUTH_KEY)||'null')}catch{return null}}
  function saveSession(v){localStorage.setItem(AUTH_KEY,JSON.stringify(v))}
  async function apiFetch(path,opts={}){
    let s=session();
    const headers={apikey:SUPABASE_KEY,'Content-Type':'application/json',...(opts.headers||{})};
    if(s?.access_token)headers.Authorization=`Bearer ${s.access_token}`;
    let r=await fetch(`${SUPABASE_URL}${path}`,{...opts,headers});
    if(r.status===401&&s?.refresh_token){
      const rr=await fetch(`${SUPABASE_URL}/auth/v1/token?grant_type=refresh_token`,{method:'POST',headers:{apikey:SUPABASE_KEY,'Content-Type':'application/json'},body:JSON.stringify({refresh_token:s.refresh_token})});
      if(rr.ok){s=await rr.json();saveSession(s);headers.Authorization=`Bearer ${s.access_token}`;r=await fetch(`${SUPABASE_URL}${path}`,{...opts,headers});}
    }
    const text=await r.text();let data=null;try{data=text?JSON.parse(text):null}catch{data=text}
    if(!r.ok)throw new Error(data?.message||data?.error_description||data?.error||`Erro ${r.status}`);
    return data;
  }
  const rpc=(name,payload={})=>apiFetch(`/rest/v1/rpc/${name}`,{method:'POST',body:JSON.stringify(payload)});
  function toast(msg){const t=$('#toast');if(!t)return;t.textContent=msg;t.classList.add('show');clearTimeout(toast.timer);toast.timer=setTimeout(()=>t.classList.remove('show'),3000)}
  function defaults(st={}){
    return {
      kicker:st.client_services_kicker||'Experiências',
      title:st.client_services_title||'Nossos serviços',
      intro:st.client_services_intro||'Trabalhamos com uma seleção premium de atendimentos para manter sua experiência mais prática e elegante. Ao tocar em Agendar agora, você verá todos os serviços disponíveis com seus respectivos valores e duração.',
      bullets:Array.isArray(st.client_services_bullets)?st.client_services_bullets.join('\n'):(st.client_services_bullets||'Cortes, barba tradicional e barba express\nCombos completos com barba, sobrancelha e barboterapia\nBarboterapia, sobrancelha, pezinho detalhes e cabeça raspada'),
      cta:st.client_services_cta||'Ver serviços e agendar →'
    };
  }

  async function enhance(){
    const form=$('#v1224ClientAppearance');
    if(!form||form.dataset.v1228Presentation==='1')return;
    form.dataset.v1228Presentation='1';

    try{
      const boot=await rpc('barberium_staff_settings_bootstrap');
      const unitId=$('#settingsUnitSelect')?.value;
      const unit=(boot.units||[]).find(u=>u.id===unitId);
      if(!unit)return;
      const d=defaults(unit.settings||{});
      const media=form.querySelector('.v1224-media-grid');
      if(!media)return;
      const block=document.createElement('div');
      block.id='v1228PresentationFields';
      block.innerHTML=`
        <h3 class="settings-section-title">Apresentação da página inicial</h3>
        <p class="settings-hint">Personalize o bloco que apresenta os serviços ao cliente. Em “Destaques”, use uma linha para cada item.</p>
        <div class="settings-two">
          <div class="field"><label>Chamada da seção</label><input id="v1228ServicesKicker" value="${esc(d.kicker)}" placeholder="Ex.: Experiências"></div>
          <div class="field"><label>Título da seção</label><input id="v1228ServicesTitle" value="${esc(d.title)}" placeholder="Ex.: Nossos serviços"></div>
        </div>
        <div class="field"><label>Texto de apresentação</label><textarea id="v1228ServicesIntro" rows="5" placeholder="Conte ao cliente como é a experiência da barbearia.">${esc(d.intro)}</textarea></div>
        <div class="field"><label>Destaques</label><textarea id="v1228ServicesBullets" rows="5" placeholder="Uma linha por destaque">${esc(d.bullets)}</textarea><small class="v1224-helper">Deixe vazio se não quiser mostrar a lista.</small></div>
        <div class="field"><label>Texto do botão</label><input id="v1228ServicesCta" value="${esc(d.cta)}" placeholder="Ex.: Ver serviços e agendar →"></div>`;
      form.insertBefore(block,media);

      form.onsubmit=async event=>{
        event.preventDefault();
        if(form.dataset.uploading==='1'){toast('Aguarde o envio da imagem terminar.');return;}
        const button=form.querySelector('[type=submit]');
        button.disabled=true;button.textContent='Salvando…';
        try{
          const fresh=await rpc('barberium_staff_settings_bootstrap');
          const id=$('#settingsUnitSelect')?.value;
          const u=(fresh.units||[]).find(x=>x.id===id);
          if(!u)throw new Error('Unidade não encontrada.');
          const bullets=$('#v1228ServicesBullets',form).value.split(/\r?\n/).map(x=>x.trim()).filter(Boolean);
          const merged={...(u.settings||{}),
            client_header_subtitle:$('#v1224HeaderSubtitle',form).value.trim(),
            client_hero_label:$('#v1224HeroLabel',form).value.trim(),
            client_hero_title:$('#v1224HeroTitle',form).value.trim()||'Agende seu horário.',
            client_logo_url:$('#v1224LogoUrl',form).value.trim(),
            client_hero_image_url:$('#v1224HeroUrl',form).value.trim(),
            client_services_kicker:$('#v1228ServicesKicker',form).value.trim()||'Experiências',
            client_services_title:$('#v1228ServicesTitle',form).value.trim()||'Nossos serviços',
            client_services_intro:$('#v1228ServicesIntro',form).value.trim(),
            client_services_bullets:bullets,
            client_services_cta:$('#v1228ServicesCta',form).value.trim()||'Ver serviços e agendar →'
          };
          await rpc('barberium_staff_save_unit',{
            p_unit_id:u.id,p_name:u.name,p_city:u.city||null,p_state:u.state||null,p_whatsapp:u.whatsapp||null,p_maps_url:u.maps_url||null,p_is_active:u.is_active!==false,p_settings:merged
          });
          toast('Personalização salva.');button.textContent='Salvo ✓';
          setTimeout(()=>{if(form.isConnected){button.disabled=false;button.textContent='Salvar personalização'}},1400);
        }catch(err){toast(err?.message||'Não foi possível salvar.');button.disabled=false;button.textContent='Salvar personalização';}
      };
    }catch(err){console.error('Barberium v12.28 apresentação:',err)}
  }

  const observer=new MutationObserver(()=>setTimeout(enhance,0));
  observer.observe(document.documentElement,{childList:true,subtree:true});
  if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',()=>setTimeout(enhance,200),{once:true});
  else setTimeout(enhance,200);
  setTimeout(enhance,800);setTimeout(enhance,1600);
})();


/* Barberium v12.29 · correção cirúrgica de "Minhas comissões" para barbeiros.
   Bypassa a cadeia de interceptadores de fetch apenas nesta RPC.
   Nenhuma outra chamada da Área da Equipe é alterada. */
(() => {
  const previousFetch=window.fetch.bind(window);
  const TARGET=/\/rest\/v1\/rpc\/barberium_staff_my_commissions(?:\?|$)/;

  function headersObject(headers){
    if(!headers)return {};
    if(headers instanceof Headers)return Object.fromEntries(headers.entries());
    if(Array.isArray(headers))return Object.fromEntries(headers);
    return {...headers};
  }

  function xhrResponse(url,init={}){
    return new Promise((resolve,reject)=>{
      const xhr=new XMLHttpRequest();
      xhr.open(init.method||'GET',url,true);
      xhr.timeout=12000;

      for(const [key,value] of Object.entries(headersObject(init.headers))){
        if(value!=null)xhr.setRequestHeader(key,String(value));
      }

      if(init.signal){
        if(init.signal.aborted){xhr.abort();reject(new DOMException('Abortado','AbortError'));return}
        init.signal.addEventListener('abort',()=>xhr.abort(),{once:true});
      }

      xhr.onload=()=>{
        const responseHeaders=new Headers();
        const raw=xhr.getAllResponseHeaders().trim();
        if(raw){
          for(const line of raw.split(/[\r\n]+/)){
            const i=line.indexOf(':');
            if(i>0)responseHeaders.append(line.slice(0,i).trim(),line.slice(i+1).trim());
          }
        }
        resolve(new Response(xhr.responseText,{
          status:xhr.status,
          statusText:xhr.statusText,
          headers:responseHeaders
        }));
      };
      xhr.onerror=()=>reject(new TypeError('Falha de conexão ao carregar suas comissões.'));
      xhr.ontimeout=()=>reject(new Error('A conexão demorou mais que o esperado. Tente novamente.'));
      xhr.onabort=()=>reject(new DOMException('Abortado','AbortError'));

      xhr.send(init.body??null);
    });
  }

  window.fetch=function(input,init={}){
    const url=typeof input==='string'?input:input?.url;
    if(typeof url==='string'&&TARGET.test(url)){
      return xhrResponse(url,init);
    }
    return previousFetch(input,init);
  };
})();
