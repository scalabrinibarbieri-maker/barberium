/* Barberium v12.32 · acesso do cliente por nome + WhatsApp
   Regra do produto: nome + número abrem/criam o perfil do cliente.
*/
(() => {
  const SUPABASE_URL='https://pmvvawbaqylspxfmxezw.supabase.co';
  const SUPABASE_KEY='sb_publishable_CveglntZGjChE89lPcsQcg_EvBnYmKo';
  const SHOP_SLUG='scalabrini-barbieri';
  const SESSION_KEY='barberium_scalabrini_session_v1';

  const $=(s,r=document)=>r.querySelector(s);

  function getSession(){
    try{return JSON.parse(localStorage.getItem(SESSION_KEY)||'null')}catch{return null}
  }

  function saveSession(v){
    localStorage.setItem(SESSION_KEY,JSON.stringify(v));
  }

  function formatPhone(v=''){
    const digits=String(v).replace(/\D/g,'').replace(/^55(?=\d{10,11}$)/,'').slice(0,11);
    if(digits.length<=2)return digits;
    if(digits.length<=7)return `(${digits.slice(0,2)}) ${digits.slice(2)}`;
    return `(${digits.slice(0,2)}) ${digits.slice(2,7)}-${digits.slice(7)}`;
  }

  async function rpc(name,payload={}){
    const r=await fetch(`${SUPABASE_URL}/rest/v1/rpc/${name}`,{
      method:'POST',
      headers:{
        'Content-Type':'application/json',
        apikey:SUPABASE_KEY,
        Authorization:`Bearer ${SUPABASE_KEY}`
      },
      body:JSON.stringify(payload)
    });
    const text=await r.text();
    let data=null;
    try{data=text?JSON.parse(text):null}catch{data=text}
    if(!r.ok){
      const msg=data?.message||data?.hint||data?.error||`Erro ${r.status}`;
      throw new Error(msg);
    }
    return data;
  }

  function toast(msg){
    const el=$('#toast');
    if(!el)return;
    el.textContent=msg;
    el.classList.add('show');
    clearTimeout(toast.timer);
    toast.timer=setTimeout(()=>el.classList.remove('show'),2600);
  }

  function formHtml(){
    return `
      <form class="form-grid" data-v1232-profile-form>
        <div class="field">
          <label>Nome e sobrenome</label>
          <input name="name" autocomplete="name" required placeholder="Seu nome completo">
        </div>
        <div class="field">
          <label>WhatsApp</label>
          <input name="phone" inputmode="tel" autocomplete="tel" required placeholder="(11) 99999-9999">
        </div>
        <button class="gold-button" type="submit">Acessar meu perfil</button>
      </form>`;
  }

  function bindForm(root){
    const form=$('[data-v1232-profile-form]',root);
    if(!form||form.dataset.bound==='1')return;
    form.dataset.bound='1';

    const phone=$('input[name="phone"]',form);
    if(phone)phone.oninput=e=>e.target.value=formatPhone(e.target.value);

    form.onsubmit=async e=>{
      e.preventDefault();
      const btn=form.querySelector('[type="submit"]');
      const fd=new FormData(form);
      const name=String(fd.get('name')||'').trim();
      const phoneDigits=String(fd.get('phone')||'').replace(/\D/g,'');

      if(name.split(/\s+/).length<2){
        toast('Informe nome e sobrenome.');
        return;
      }
      if(phoneDigits.length<10){
        toast('Informe um WhatsApp válido.');
        return;
      }

      btn.disabled=true;
      btn.textContent='Acessando…';

      try{
        const res=await rpc('barberium_customer_open_profile',{
          p_barbershop_slug:SHOP_SLUG,
          p_full_name:name,
          p_phone:phoneDigits
        });

        if(!res?.access_token||!res?.customer){
          throw new Error('PROFILE_ACCESS_FAILED');
        }

        saveSession({
          access_token:res.access_token,
          customer:res.customer
        });

        location.href=`${location.pathname}?view=appointments`;
      }catch(err){
        console.error('Acesso ao perfil:',err);
        toast('Não foi possível abrir o perfil agora. Tente novamente.');
        btn.disabled=false;
        btn.textContent='Acessar meu perfil';
      }
    };
  }

  function ensureProfileAccess(){
    const profileView=$('[data-view="profile"]');
    const root=$('#profileContent');
    if(!profileView||!root)return;

    const session=getSession();
    if(session?.access_token)return;

    if(root.dataset.v1232Access==='1'){
      bindForm(root);
      return;
    }

    root.dataset.v1232Access='1';
    root.innerHTML=`
      <section class="profile-section" id="v1232ProfileAccess">
        <h3>Acessar meu perfil</h3>
        <p>Informe seu nome e WhatsApp. Seus horários vinculados a esse número aparecerão aqui.</p>
        ${formHtml()}
      </section>
      <div class="empty-state">
        <h3>Ainda não tem horário?</h3>
        <p>Você também pode criar seu perfil fazendo seu primeiro agendamento.</p>
        <button class="gold-button" data-v1232-book type="button">Agendar agora →</button>
      </div>`;

    $('[data-v1232-book]',root)?.addEventListener('click',()=>{
      document.querySelector('[data-nav="booking"]')?.click();
    });

    bindForm(root);
  }

  function openOtherDevice(){
    const back=$('#modalBackdrop');
    const box=$('#modalBox');
    if(!back||!box)return;

    box.innerHTML=`
      <h3>Acessar perfil</h3>
      <p>Informe nome e WhatsApp para abrir os horários desse cliente neste aparelho.</p>
      ${formHtml()}
      <div class="modal-actions">
        <button class="secondary-button" data-v1232-close type="button">Cancelar</button>
      </div>`;

    back.classList.add('open');
    back.setAttribute('aria-hidden','false');

    $('[data-v1232-close]',box)?.addEventListener('click',()=>{
      back.classList.remove('open');
      back.setAttribute('aria-hidden','true');
    });

    bindForm(box);
  }

  document.addEventListener('click',e=>{
    const other=e.target.closest?.('#otherDevice');
    if(other){
      e.preventDefault();
      e.stopPropagation();
      e.stopImmediatePropagation();
      openOtherDevice();
      return;
    }

    if(e.target.closest?.('[data-nav="profile"]')){
      setTimeout(ensureProfileAccess,0);
      setTimeout(ensureProfileAccess,120);
    }
  },true);

  function boot(){
    const root=$('#profileContent');
    if(!root)return;

    new MutationObserver(()=>{
      if(!getSession()?.access_token)ensureProfileAccess();
    }).observe(root,{childList:true,subtree:false});

    ensureProfileAccess();
  }

  if(document.readyState==='loading'){
    document.addEventListener('DOMContentLoaded',boot,{once:true});
  }else{
    boot();
  }

  setTimeout(boot,400);
})();


/* Barberium v12.34 · animação premium dos profissionais
   Apenas apresentação visual da etapa "Escolha o profissional".
*/
(() => {
  const stage=document.querySelector('#bookingStage');
  if(!stage)return;

  const reduced=window.matchMedia?.('(prefers-reduced-motion: reduce)')?.matches===true;
  let lastSelected=null;

  const style=document.createElement('style');
  style.id='barberiumProfessionalMotionV1234';
  style.textContent=`
    @keyframes v1234ProEnter{
      0%{opacity:0;transform:translateY(14px) scale(.985)}
      100%{opacity:1;transform:translateY(0) scale(1)}
    }
    @keyframes v1234ProBreathe{
      0%,100%{transform:translate3d(var(--v1234-x,0px),var(--v1234-y,0px),0) scale(1.035)}
      50%{transform:translate3d(var(--v1234-x,0px),calc(var(--v1234-y,0px) - 1px),0) scale(1.075)}
    }
    @keyframes v1234ProSelect{
      0%{transform:translateY(0) scale(1)}
      55%{transform:translateY(-3px) scale(1.035)}
      100%{transform:translateY(-2px) scale(1.022)}
    }

    .pro-choice{
      overflow:hidden;
      transition:
        transform .2s cubic-bezier(.2,.75,.25,1),
        border-color .2s ease,
        background-color .2s ease,
        box-shadow .22s ease;
      will-change:transform;
    }

    .pro-choice.v1234-enter{
      opacity:0;
      animation:v1234ProEnter .46s cubic-bezier(.18,.8,.24,1) forwards;
      animation-delay:var(--v1234-delay,0ms);
    }

    .pro-choice img{
      transform-origin:50% 45%;
      will-change:transform;
      animation:v1234ProBreathe 6.2s ease-in-out infinite;
      transition:filter .22s ease;
    }

    .pro-choice.selected{
      transform:translateY(-2px) scale(1.022);
      box-shadow:
        0 14px 34px rgba(0,0,0,.28),
        0 0 0 1px rgba(226,186,99,.12);
    }

    .pro-choice.selected.v1234-select-pop{
      animation:v1234ProSelect .25s cubic-bezier(.2,.85,.25,1) both;
    }

    .pro-choice.selected img{
      filter:brightness(1.035) contrast(1.015);
    }

    @media (hover:hover) and (pointer:fine){
      .pro-choice:hover{
        transform:translateY(-2px) scale(1.012);
        border-color:rgba(226,186,99,.38);
        box-shadow:0 12px 28px rgba(0,0,0,.22);
      }
    }

    @media (prefers-reduced-motion:reduce){
      .pro-choice,
      .pro-choice.v1234-enter,
      .pro-choice.selected.v1234-select-pop,
      .pro-choice img{
        animation:none!important;
        transition:none!important;
        opacity:1!important;
        transform:none!important;
      }
    }
  `;
  if(!document.querySelector('#barberiumProfessionalMotionV1234')){
    document.head.appendChild(style);
  }

  function resetImage(card){
    const img=card.querySelector('img');
    if(!img)return;
    img.style.setProperty('--v1234-x','0px');
    img.style.setProperty('--v1234-y','0px');
  }

  function bindParallax(card){
    if(card.dataset.v1234Bound==='1')return;
    card.dataset.v1234Bound='1';

    const img=card.querySelector('img');
    if(!img)return;

    card.addEventListener('pointermove',e=>{
      if(reduced||e.pointerType!=='mouse')return;
      const r=card.getBoundingClientRect();
      const nx=((e.clientX-r.left)/r.width)-.5;
      const ny=((e.clientY-r.top)/r.height)-.5;
      img.style.setProperty('--v1234-x',`${(nx*3.2).toFixed(2)}px`);
      img.style.setProperty('--v1234-y',`${(ny*2.2).toFixed(2)}px`);
    });

    card.addEventListener('pointerleave',()=>resetImage(card));

    card.addEventListener('pointerdown',e=>{
      lastSelected=card.dataset.pro||null;
      if(reduced||e.pointerType==='mouse')return;
      const r=card.getBoundingClientRect();
      const nx=((e.clientX-r.left)/r.width)-.5;
      const ny=((e.clientY-r.top)/r.height)-.5;
      img.style.setProperty('--v1234-x',`${(nx*2.4).toFixed(2)}px`);
      img.style.setProperty('--v1234-y',`${(ny*1.8).toFixed(2)}px`);
      setTimeout(()=>resetImage(card),320);
    },{passive:true});
  }

  function enhance(){
    const cards=[...stage.querySelectorAll('.pro-choice')];

    if(!cards.length){
      delete stage.dataset.v1234ProScreen;
      return;
    }

    const firstAppearance=stage.dataset.v1234ProScreen!=='1';
    stage.dataset.v1234ProScreen='1';

    cards.forEach((card,i)=>{
      bindParallax(card);

      if(firstAppearance&&!reduced){
        card.classList.add('v1234-enter');
        card.style.setProperty('--v1234-delay',`${i*85}ms`);
      }

      if(lastSelected&&card.dataset.pro===lastSelected&&card.classList.contains('selected')&&!reduced){
        card.classList.add('v1234-select-pop');
        setTimeout(()=>card.classList.remove('v1234-select-pop'),320);
      }
    });

    lastSelected=null;
  }

  new MutationObserver(enhance).observe(stage,{childList:true,subtree:true});
  enhance();
})();
