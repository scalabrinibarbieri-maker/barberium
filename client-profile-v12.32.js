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
