/* Barberium v12.43 · personalização pública da área do cliente
   Correção: a capa correta é carregada antes da home ser revelada.
*/
(() => {
  const SUPABASE_URL='https://pmvvawbaqylspxfmxezw.supabase.co';
  const SUPABASE_KEY='sb_publishable_CveglntZGjChE89lPcsQcg_EvBnYmKo';
  const SHOP_SLUG='scalabrini-barbieri';
  const UNIT_SLUG='braganca-paulista';
  const SPLASH_PENDING_CLASS='barberium-splash-pending';
  const HERO_PENDING_CLASS='barberium-hero-pending';
  const LOGO_CACHE_KEY=`barberium:brand-logo:${SHOP_SLUG}:${UNIT_SLUG}`;
  const MIN_SPLASH_MS=360;

  const $=(s,r=document)=>r.querySelector(s);
  const $$=(s,r=document)=>[...r.querySelectorAll(s)];
  const setText=(el,value)=>{if(el&&value!=null&&el.textContent!==String(value))el.textContent=String(value)};
  const setSrc=(el,value)=>{if(el&&value&&el.getAttribute('src')!==value)el.setAttribute('src',value)};

  document.documentElement.classList.add(HERO_PENDING_CLASS);

  (() => {
    if(document.getElementById('barberiumHeroReadyV1243'))return;
    const style=document.createElement('style');
    style.id='barberiumHeroReadyV1243';
    style.textContent=`
      .hero-bg{
        transition:opacity .20s ease!important;
      }
      html.${HERO_PENDING_CLASS} .hero-bg{
        opacity:0!important;
      }
    `;
    document.head.appendChild(style);
  })();

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

  function waitForImage(img,url,timeout=5000){
    return new Promise(resolve=>{
      if(!img||!url){resolve(false);return}

      let done=false;
      const finish=ok=>{
        if(done)return;
        done=true;
        clearTimeout(timer);
        img.removeEventListener('load',onLoad);
        img.removeEventListener('error',onError);
        resolve(ok);
      };
      const onLoad=()=>finish(true);
      const onError=()=>finish(false);
      const timer=setTimeout(()=>finish(false),timeout);

      img.addEventListener('load',onLoad,{once:true});
      img.addEventListener('error',onError,{once:true});

      if(img.getAttribute('src')!==url)img.setAttribute('src',url);

      if(img.complete&&img.naturalWidth>0){
        queueMicrotask(()=>finish(true));
      }
    });
  }

  async function prepareHero(url){
    const hero=$('.hero-bg');
    if(!hero){
      document.documentElement.classList.remove(HERO_PENDING_CLASS);
      return;
    }

    let ok=await waitForImage(hero,url,5000);

    if(!ok&&url!=='./assets/barbearia.webp'){
      ok=await waitForImage(hero,'./assets/barbearia.webp',2500);
    }

    document.documentElement.classList.remove(HERO_PENDING_CLASS);
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
      const next=current
        .replaceAll('Scalabrini Barbieri',shopName)
        .replaceAll('Scalabrini Barbiere',shopName);
      if(next!==current)p.textContent=next;
    });
  }

  async function applyBranding(catalog){
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
    if(meta){
      meta.setAttribute(
        'content',
        `${heroTitle.replace(/\.$/,'')} na ${shopName} — ${unitName}.`
      );
    }

    setText($('.brand-button strong'),shopName);
    setText($('.brand-button small'),headerSubtitle);
    setText($('.hero-unit'),heroLabel);
    setText($('.hero-content h1'),heroTitle);
    setText($('.unit-card h2'),unitName);

    setSrc($('.mini-logo'),logo);
    setSrc($('.hero-logo'),logo);
    setSrc($('.unit-logo-wrap img'),logo);

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

    /*
      Só libera a capa depois da imagem correta estar pronta.
      Enquanto isso, a imagem antiga fica invisível atrás do splash.
    */
    await prepareHero(heroImage);
  }

  async function boot(){
    try{
      const catalog=await rpc('barberium_get_catalog',{
        p_barbershop_slug:SHOP_SLUG,
        p_unit_slug:UNIT_SLUG
      });

      await applyBranding(catalog);
    }catch(err){
      console.error('Barberium v12.43 branding:',err);
      await prepareHero('./assets/barbearia.webp');
    }finally{
      document.documentElement.classList.remove(HERO_PENDING_CLASS);
      revealBranding();
    }
  }

  if(document.readyState==='loading'){
    document.addEventListener('DOMContentLoaded',boot,{once:true});
  }else{
    boot();
  }
})();

/* Barberium v12.44 · entrada cinematográfica da hero / logo
   Somente apresentação visual da home.
*/
(() => {
  const reduced=window.matchMedia?.('(prefers-reduced-motion: reduce)')?.matches===true;
  let started=false;

  function injectStyles(){
    if(document.getElementById('barberiumHeroMotionV1244'))return;

    const style=document.createElement('style');
    style.id='barberiumHeroMotionV1244';
    style.textContent=`
      @keyframes v1244LogoEnter{
        0%{opacity:0;transform:translateY(12px) scale(.92);filter:blur(2px)}
        68%{opacity:1;transform:translateY(-2px) scale(1.018);filter:blur(0)}
        100%{opacity:1;transform:translateY(0) scale(1);filter:blur(0)}
      }

      @keyframes v1244LineDraw{
        0%{opacity:0;transform:scaleX(0)}
        25%{opacity:.9}
        100%{opacity:.72;transform:scaleX(1)}
      }

      @keyframes v1244CopyIn{
        0%{opacity:0;transform:translateY(15px);filter:blur(1.5px)}
        100%{opacity:1;transform:translateY(0);filter:blur(0)}
      }

      @keyframes v1244Breathe{
        0%,20%,100%{transform:scale(1)}
        43%{transform:scale(1.022)}
        58%{transform:scale(1.008)}
      }

      @keyframes v1244Glint{
        0%,78%{
          opacity:0;
          clip-path:polygon(-28% 0,-12% 0,-30% 100%,-46% 100%);
        }
        81%{opacity:0}
        84%{
          opacity:.54;
          clip-path:polygon(2% 0,18% 0,0 100%,-16% 100%);
        }
        88%{
          opacity:.44;
          clip-path:polygon(82% 0,98% 0,80% 100%,64% 100%);
        }
        91%,100%{
          opacity:0;
          clip-path:polygon(128% 0,144% 0,126% 100%,110% 100%);
        }
      }

      .v1244-logo-stage{
        position:relative;
        display:grid;
        place-items:center;
        width:94px;
        height:94px;
        margin-bottom:18px;
        isolation:isolate;
        transform-origin:50% 52%;
      }

      .v1244-logo-stage .hero-logo,
      .v1244-logo-glint{
        grid-area:1/1;
        width:100%!important;
        height:100%!important;
        margin:0!important;
        object-fit:contain;
      }

      .v1244-logo-stage .hero-logo{
        position:relative;
        z-index:1;
      }

      .v1244-logo-glint{
        position:absolute;
        inset:0;
        z-index:2;
        pointer-events:none;
        opacity:0;
        filter:
          brightness(1.82)
          sepia(.78)
          saturate(1.65)
          drop-shadow(0 0 8px rgba(229,196,119,.24));
      }

      .v1244-logo-stage::after{
        content:"";
        position:absolute;
        z-index:3;
        left:4px;
        bottom:-11px;
        width:54px;
        height:1px;
        border-radius:999px;
        background:linear-gradient(
          90deg,
          rgba(229,196,119,.95),
          rgba(229,196,119,.38),
          transparent
        );
        transform-origin:left center;
        opacity:0;
        transform:scaleX(0);
        box-shadow:0 0 10px rgba(229,196,119,.16);
      }

      .hero-content.v1244-intro .v1244-logo-stage,
      .hero-content.v1244-intro .hero-unit,
      .hero-content.v1244-intro > h1,
      .hero-content.v1244-intro .hero-welcome,
      .hero-content.v1244-intro .hero-cta{
        opacity:0;
      }

      .hero-content.v1244-intro .hero-unit,
      .hero-content.v1244-intro > h1,
      .hero-content.v1244-intro .hero-welcome,
      .hero-content.v1244-intro .hero-cta{
        transform:translateY(15px);
      }

      .hero-content.v1244-play .v1244-logo-stage{
        animation:v1244LogoEnter .70s cubic-bezier(.16,.82,.24,1) both;
      }

      .hero-content.v1244-play .v1244-logo-stage::after{
        animation:v1244LineDraw .54s .36s cubic-bezier(.2,.8,.25,1) both;
      }

      .hero-content.v1244-play .hero-unit{
        animation:v1244CopyIn .52s .48s cubic-bezier(.2,.8,.25,1) both;
      }

      .hero-content.v1244-play > h1{
        animation:v1244CopyIn .68s .64s cubic-bezier(.18,.82,.25,1) both;
      }

      .hero-content.v1244-play .hero-welcome{
        animation:v1244CopyIn .52s .78s cubic-bezier(.2,.8,.25,1) both;
      }

      .hero-content.v1244-play .hero-cta{
        animation:v1244CopyIn .56s .91s cubic-bezier(.18,.82,.25,1) both;
      }

      .hero-content.v1244-done .v1244-logo-stage,
      .hero-content.v1244-done .hero-unit,
      .hero-content.v1244-done > h1,
      .hero-content.v1244-done .hero-welcome,
      .hero-content.v1244-done .hero-cta{
        opacity:1;
        transform:none;
        filter:none;
      }

      .hero-content.v1244-done .v1244-logo-stage{
        animation:v1244Breathe 8.8s 1.8s ease-in-out infinite;
      }

      .hero-content.v1244-done .v1244-logo-stage::after{
        opacity:.72;
        transform:scaleX(1);
      }

      .hero-content.v1244-done .v1244-logo-glint{
        animation:v1244Glint 8.8s 1.8s ease-in-out infinite;
      }

      @media(min-width:700px){
        .v1244-logo-stage{
          width:112px;
          height:112px;
          margin-bottom:22px;
        }
        .v1244-logo-stage::after{
          width:66px;
          bottom:-12px;
        }
      }

      @media(prefers-reduced-motion:reduce){
        .hero-content.v1244-intro .v1244-logo-stage,
        .hero-content.v1244-intro .hero-unit,
        .hero-content.v1244-intro > h1,
        .hero-content.v1244-intro .hero-welcome,
        .hero-content.v1244-intro .hero-cta{
          opacity:1!important;
          transform:none!important;
          filter:none!important;
        }

        .hero-content.v1244-play .v1244-logo-stage,
        .hero-content.v1244-play .hero-unit,
        .hero-content.v1244-play > h1,
        .hero-content.v1244-play .hero-welcome,
        .hero-content.v1244-play .hero-cta,
        .hero-content.v1244-done .v1244-logo-stage,
        .hero-content.v1244-done .v1244-logo-glint,
        .hero-content.v1244-logo-stage::after{
          animation:none!important;
        }

        .v1244-logo-glint{display:none!important}
        .v1244-logo-stage::after{
          opacity:.72!important;
          transform:scaleX(1)!important;
        }
      }
    `;
    document.head.appendChild(style);
  }

  function prepareLogo(){
    const logo=document.querySelector('.hero-content .hero-logo');
    if(!logo)return null;

    let stage=logo.closest('.v1244-logo-stage');
    if(stage)return stage;

    stage=document.createElement('span');
    stage.className='v1244-logo-stage';
    stage.setAttribute('aria-hidden','false');

    logo.parentNode.insertBefore(stage,logo);
    stage.appendChild(logo);

    const glint=logo.cloneNode(false);
    glint.className='v1244-logo-glint';
    glint.removeAttribute('alt');
    glint.setAttribute('aria-hidden','true');
    stage.appendChild(glint);

    const sync=()=>{glint.src=logo.currentSrc||logo.src};
    sync();

    new MutationObserver(sync).observe(logo,{
      attributes:true,
      attributeFilter:['src','srcset']
    });

    return stage;
  }

  function finish(){
    const content=document.querySelector('.hero-content');
    if(!content)return;

    content.classList.remove('v1244-intro','v1244-play');
    content.classList.add('v1244-done');
  }

  function play(){
    if(started)return;
    started=true;

    const content=document.querySelector('.hero-content');
    if(!content)return;

    if(reduced){
      finish();
      return;
    }

    requestAnimationFrame(()=>{
      requestAnimationFrame(()=>{
        content.classList.add('v1244-play');
      });
    });

    setTimeout(finish,1650);
  }

  function readyToPlay(){
    return !document.documentElement.classList.contains('barberium-splash-pending')
      && !document.documentElement.classList.contains('barberium-hero-pending');
  }

  function boot(){
    injectStyles();

    const content=document.querySelector('.hero-content');
    if(!content)return;

    prepareLogo();

    if(!content.classList.contains('v1244-done')){
      content.classList.add('v1244-intro');
    }

    if(readyToPlay()){
      play();
      return;
    }

    if(document.documentElement.dataset.v1244Observed!=='1'){
      document.documentElement.dataset.v1244Observed='1';

      const observer=new MutationObserver(()=>{
        if(readyToPlay()){
          observer.disconnect();
          play();
        }
      });

      observer.observe(document.documentElement,{
        attributes:true,
        attributeFilter:['class']
      });
    }

    // Failsafe visual: nunca deixa conteúdo preso invisível.
    setTimeout(()=>{
      if(!started)play();
    },5200);
  }

  if(document.readyState==='loading'){
    document.addEventListener('DOMContentLoaded',boot,{once:true});
  }else{
    boot();
  }
})();

