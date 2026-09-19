/* Barberium v12.28 · personalização pública da área do cliente */
(() => {
  const SUPABASE_URL='https://pmvvawbaqylspxfmxezw.supabase.co';
  const SUPABASE_KEY='sb_publishable_CveglntZGjChE89lPcsQcg_EvBnYmKo';
  const SHOP_SLUG='scalabrini-barbieri';
  const UNIT_SLUG='braganca-paulista';
  const SPLASH_PENDING_CLASS='barberium-splash-pending';
  const LOGO_CACHE_KEY=`barberium:brand-logo:${SHOP_SLUG}:${UNIT_SLUG}`;
  const MIN_SPLASH_MS=360;

  const $=(s,r=document)=>r.querySelector(s);
  const $$=(s,r=document)=>[...r.querySelectorAll(s)];
  const setText=(el,value)=>{if(el&&value!=null&&el.textContent!==String(value))el.textContent=String(value)};
  const setSrc=(el,value)=>{if(el&&value&&el.getAttribute('src')!==value)el.setAttribute('src',value)};

  function cacheSplashLogo(value){
    if(!value)return;
    try{localStorage.setItem(LOGO_CACHE_KEY,value)}catch{}
    setSrc($('#barberiumSplashLogo'),value);
  }

  function revealBranding(){
    clearTimeout(window.__barberiumSplashFallbackTimer);
    const started=Number(window.__barberiumSplashStartedAt)||0;
    const elapsed=started?performance.now()-started:MIN_SPLASH_MS;
    const wait=Math.max(0,MIN_SPLASH_MS-elapsed);
    setTimeout(()=>{
      document.documentElement.classList.remove(SPLASH_PENDING_CLASS);
    },wait);
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
    if(!r.ok)throw new Error(data?.message||data?.error||`Erro ${r.status}`);
    return data;
  }

  function headerDefault(unit){
    const name=String(unit?.name||'');
    return name.replace(/\s+[—–-]\s+/,' • ');
  }

  function formatPhone(v=''){
    const digits=String(v).replace(/\D/g,'');
    if(digits.startsWith('55')&&digits.length>=12){
      const local=digits.slice(2);
      const ddd=local.slice(0,2);
      const number=local.slice(2);
      if(number.length===9)return `+55 ${ddd} ${number.slice(0,5)}-${number.slice(5)}`;
      if(number.length===8)return `+55 ${ddd} ${number.slice(0,4)}-${number.slice(4)}`;
    }
    return v||'';
  }

  function whatsappHref(v=''){
    const digits=String(v).replace(/\D/g,'');
    return digits?`https://wa.me/${digits}`:'';
  }

  function presentationBullets(value){
    if(Array.isArray(value))return value.map(v=>String(v||'').trim()).filter(Boolean);
    if(typeof value==='string')return value.split(/\r?\n/).map(v=>v.trim()).filter(Boolean);
    return [
      'Cortes, barba tradicional e barba express',
      'Combos completos com barba, sobrancelha e barboterapia',
      'Barboterapia, sobrancelha, pezinho detalhes e cabeça raspada'
    ];
  }

  function applyPresentation(st={}){
    const kicker=String(st.client_services_kicker||'Experiências').trim();
    const title=String(st.client_services_title||'Nossos serviços').trim();
    const intro=String(st.client_services_intro||'Trabalhamos com uma seleção premium de atendimentos para manter sua experiência mais prática e elegante. Ao tocar em Agendar agora, você verá todos os serviços disponíveis com seus respectivos valores e duração.').trim();
    const bullets=presentationBullets(st.client_services_bullets);
    const cta=String(st.client_services_cta||'Ver serviços e agendar →').trim();

    setText($('.home-section .section-title span'),kicker);
    setText($('.home-section .section-title h2'),title);
    setText($('.services-summary-card > p'),intro);
    const list=$('.services-summary-list');
    if(list){
      list.innerHTML='';
      for(const item of bullets){
        const li=document.createElement('li');
        li.textContent=item;
        list.appendChild(li);
      }
      list.hidden=bullets.length===0;
    }
    setText($('.inline-book-button'),cta);
  }

  function applyDynamicTexts(brand){
    const {shopName,unitName}=brand;

    const confirmation=$('.confirmation');
    if(confirmation){
      const p=confirmation.querySelector(':scope > p');
      const wanted=`Esperamos você na ${shopName} — ${unitName}.`;
      setText(p,wanted);
    }

    const profileHead=$('[data-view="profile"] .page-heading p');
    if(profileHead){
      setText(profileHead,`Os dados usados nos seus agendamentos da ${shopName}.`);
    }

    $$('#profileContent p').forEach(p=>{
      if(!p.textContent)return;
      const current=p.textContent;
      const next=current.replaceAll('Scalabrini Barbieri',shopName).replaceAll('Scalabrini Barbiere',shopName);
      if(next!==current)p.textContent=next;
    });
  }

  function applyBranding(catalog){
    const b=catalog?.barbershop||{};
    const u=catalog?.unit||{};
    const st=u.settings||{};

    const shopName=String(b.name||'Scalabrini Barbiere').trim();
    const unitName=String(u.name||'II Unidade — Bragança Paulista').trim();
    const headerSubtitle=String(st.client_header_subtitle||headerDefault(u)||unitName).trim();
    const heroLabel=String(st.client_hero_label||'Casa Scalabrini').trim();
    const heroTitle=String(st.client_hero_title||'Agende seu horário.').trim();
    const logo=String(st.client_logo_url||'./assets/logo-sb.webp').trim();
    const heroImage=String(st.client_hero_image_url||'./assets/barbearia.webp').trim();

    cacheSplashLogo(logo);

    document.title=`${shopName} • ${u.city||unitName}`;
    const meta=$('meta[name="description"]');
    if(meta)meta.setAttribute('content',`${heroTitle.replace(/\.$/,'')} na ${shopName} — ${unitName}.`);

    setText($('.brand-button strong'),shopName);
    setText($('.brand-button small'),headerSubtitle);
    setText($('.hero-unit'),heroLabel);
    setText($('.hero-content h1'),heroTitle);
    setText($('.unit-card h2'),unitName);

    setSrc($('.mini-logo'),logo);
    setSrc($('.hero-logo'),logo);
    setSrc($('.unit-logo-wrap img'),logo);
    setSrc($('.hero-bg'),heroImage);

    const heroBg=$('.hero-bg');
    if(heroBg)heroBg.alt=`Interior da ${shopName}`;
    const heroLogo=$('.hero-logo');
    if(heroLogo)heroLogo.alt=shopName;

    const whatsappStrong=$('.unit-info > div:nth-child(2) strong');
    if(u.whatsapp)setText(whatsappStrong,formatPhone(u.whatsapp));

    const whatsappLink=$('.unit-actions a[href*="wa.me"]');
    const wa=whatsappHref(u.whatsapp);
    if(whatsappLink&&wa)whatsappLink.href=wa;

    const mapsLink=$('.unit-actions a[href*="maps"]');
    if(mapsLink&&u.maps_url)mapsLink.href=u.maps_url;

    applyPresentation(st);

    const brand={shopName,unitName};
    applyDynamicTexts(brand);

    const main=$('#main');
    if(main&&!main.dataset.v1224BrandObserver){
      main.dataset.v1224BrandObserver='1';
      let timer=null;
      new MutationObserver(()=>{
        clearTimeout(timer);
        timer=setTimeout(()=>applyDynamicTexts(brand),20);
      }).observe(main,{childList:true,subtree:true});
    }
  }

  async function boot(){
    try{
      const catalog=await rpc('barberium_get_catalog',{
        p_barbershop_slug:SHOP_SLUG,
        p_unit_slug:UNIT_SLUG
      });
      applyBranding(catalog);
    }catch(err){
      console.error('Barberium v12.28 branding:',err);
    }finally{
      revealBranding();
    }
  }

  if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',boot,{once:true});
  else boot();
})();
