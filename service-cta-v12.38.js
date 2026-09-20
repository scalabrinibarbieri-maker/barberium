/* Barberium v12.38 · CTA flutuante na escolha de serviços
   Somente apresentação da etapa "Escolha o serviço".
*/
(() => {
  const STAGE_ID='bookingStage';
  let hintShown=false;
  let lastSelectedId=null;
  let bar=null;

  function injectStyles(){
    if(document.getElementById('barberiumServiceCtaV1238'))return;
    const style=document.createElement('style');
    style.id='barberiumServiceCtaV1238';
    style.textContent=`
      @keyframes v1237BarIn{
        0%{opacity:0;transform:translate(-50%,18px) scale(.975)}
        100%{opacity:1;transform:translate(-50%,0) scale(1)}
      }
      @keyframes v1237HintIn{
        0%{opacity:0;transform:translateY(8px)}
        100%{opacity:1;transform:translateY(0)}
      }
      @keyframes v1237ArrowBounce{
        0%,100%{transform:translateY(0)}
        50%{transform:translateY(5px)}
      }
      @keyframes v1237ServicePop{
        0%{transform:scale(1)}
        45%{transform:scale(1.022)}
        100%{transform:scale(1)}
      }

      #${STAGE_ID}.v1237-service-screen #serviceNext{
        position:absolute!important;
        width:1px!important;
        height:1px!important;
        padding:0!important;
        margin:0!important;
        overflow:hidden!important;
        clip:rect(0 0 0 0)!important;
        clip-path:inset(50%)!important;
        white-space:nowrap!important;
      }

      #${STAGE_ID} .choice-service{
        transition:
          transform .2s cubic-bezier(.2,.8,.25,1),
          border-color .2s ease,
          background .2s ease,
          box-shadow .2s ease;
      }

      #${STAGE_ID} .choice-service.v1237-pop{
        animation:v1237ServicePop .28s cubic-bezier(.2,.85,.3,1) both;
      }

      #${STAGE_ID} .choice-service.selected{
        box-shadow:0 10px 24px rgba(0,0,0,.20);
      }

      .v1237-service-cta{
        position:fixed;
        z-index:68;
        left:50%;
        bottom:calc(88px + env(safe-area-inset-bottom));
        width:min(calc(100% - 22px),598px);
        transform:translateX(-50%);
        display:none;
        grid-template-columns:minmax(0,1fr) auto;
        gap:10px;
        align-items:center;
        padding:10px 10px 10px 14px;
        border:1px solid rgba(226,186,99,.28);
        border-radius:18px;
        background:rgba(7,20,14,.96);
        backdrop-filter:blur(18px);
        -webkit-backdrop-filter:blur(18px);
        box-shadow:
          0 16px 40px rgba(0,0,0,.40),
          0 0 0 1px rgba(255,255,255,.025) inset;
      }

      .v1237-service-cta.show{
        display:grid;
        animation:v1237BarIn .28s cubic-bezier(.18,.8,.25,1) both;
      }

      .v1237-service-summary{
        min-width:0;
        display:flex;
        flex-direction:column;
        gap:2px;
      }

      .v1237-service-summary small{
        color:#9b927f;
        font-size:9px;
        line-height:1.2;
        text-transform:uppercase;
        letter-spacing:.08em;
        font-weight:700;
      }

      .v1237-service-summary strong{
        overflow:hidden;
        text-overflow:ellipsis;
        white-space:nowrap;
        color:var(--cream,#f3ead7);
        font-size:14px;
        line-height:1.2;
        font-weight:700;
      }

      .v1237-service-summary span{
        color:var(--gold2,#e2ba63);
        font-size:12px;
        font-weight:800;
      }

      .v1237-service-go{
        min-width:118px;
        min-height:48px;
        border:0;
        border-radius:14px;
        padding:0 15px;
        background:linear-gradient(135deg,#d6ae5b,#e5c477);
        color:#102016;
        font:800 13px/1 system-ui,-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;
        box-shadow:0 8px 18px rgba(214,174,91,.18);
      }

      .v1237-service-hint{
        position:fixed;
        z-index:69;
        left:50%;
        bottom:calc(159px + env(safe-area-inset-bottom));
        transform:translateX(-50%);
        width:max-content;
        max-width:calc(100% - 36px);
        display:flex;
        align-items:center;
        gap:7px;
        padding:8px 11px;
        border-radius:999px;
        border:1px solid rgba(226,186,99,.18);
        background:rgba(5,14,9,.95);
        color:#d8c9aa;
        font:700 10px/1.2 system-ui,-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;
        box-shadow:0 8px 22px rgba(0,0,0,.28);
        opacity:0;
        pointer-events:none;
      }

      .v1237-service-hint.show{
        animation:v1237HintIn .26s ease both;
      }

      .v1237-service-hint b{
        color:var(--gold2,#e2ba63);
        font-size:14px;
        animation:v1237ArrowBounce .9s ease-in-out infinite;
      }

      @media (min-width:700px){
        .v1237-service-cta{bottom:calc(112px + env(safe-area-inset-bottom))}
        .v1237-service-hint{bottom:calc(183px + env(safe-area-inset-bottom))}
      }

      @media (prefers-reduced-motion:reduce){
        .v1237-service-cta.show,
        .v1237-service-hint.show,
        #${STAGE_ID} .choice-service.v1237-pop,
        .v1237-service-hint b{
          animation:none!important;
        }
      }
    `;
    document.head.appendChild(style);
  }

  function ensureBar(){
    if(bar&&document.body.contains(bar))return bar;

    bar=document.createElement('div');
    bar.className='v1237-service-cta';
    bar.setAttribute('aria-hidden','true');
    bar.innerHTML=`
      <div class="v1237-service-summary">
        <small>Seu atendimento</small>
        <strong data-v1237-name></strong>
        <span data-v1237-total></span>
      </div>
      <button class="v1237-service-go" type="button">Continuar →</button>
    `;

    bar.querySelector('.v1237-service-go').addEventListener('click',()=>{
      document.querySelector('#serviceNext')?.click();
    });

    document.body.appendChild(bar);
    return bar;
  }

  function showHint(){
    if(hintShown)return;
    const stage=document.getElementById(STAGE_ID);
    if(!stage?.querySelector('.addon-section'))return;

    hintShown=true;

    let hint=document.querySelector('.v1237-service-hint');
    if(!hint){
      hint=document.createElement('div');
      hint.className='v1237-service-hint';
      hint.innerHTML='<span>Veja também os adicionais abaixo</span><b>↓</b>';
      document.body.appendChild(hint);
    }

    hint.classList.remove('show');
    void hint.offsetWidth;
    hint.classList.add('show');

    setTimeout(()=>{
      hint.classList.remove('show');
      setTimeout(()=>hint.remove(),220);
    },2600);
  }

  function hideBar(){
    const stage=document.getElementById(STAGE_ID);
    stage?.classList.remove('v1237-service-screen');

    if(bar){
      bar.classList.remove('show');
      bar.setAttribute('aria-hidden','true');
    }

    document.querySelector('.v1237-service-hint')?.remove();
  }

  function bookingViewIsActive(){
    const view=document.querySelector('[data-view="booking"]');
    return !!view?.classList.contains('active');
  }

  function enhance(){
    const stage=document.getElementById(STAGE_ID);
    if(!stage)return;

    const services=[...stage.querySelectorAll('.choice-service')];
    const selected=stage.querySelector('.choice-service.selected');

    if(!bookingViewIsActive()||!services.length||!selected){
      hideBar();
      return;
    }

    stage.classList.add('v1237-service-screen');

    const serviceId=selected.dataset.service||'';
    const name=selected.querySelector('h3')?.textContent?.trim()||'Serviço selecionado';
    const total=stage.querySelector('.booking-total-mini strong')?.textContent?.trim()
      || selected.querySelector('p strong')?.textContent?.trim()
      || '';

    const current=ensureBar();
    current.querySelector('[data-v1237-name]').textContent=name;
    current.querySelector('[data-v1237-total]').textContent=total;
    current.classList.add('show');
    current.setAttribute('aria-hidden','false');

    if(lastSelectedId&&lastSelectedId===serviceId){
      selected.classList.remove('v1237-pop');
      void selected.offsetWidth;
      selected.classList.add('v1237-pop');
      setTimeout(()=>selected.classList.remove('v1237-pop'),340);
      showHint();
    }

    lastSelectedId=null;
  }

  document.addEventListener('pointerdown',e=>{
    const service=e.target.closest?.(`#${STAGE_ID} .choice-service`);
    if(service)lastSelectedId=service.dataset.service||null;
  },true);

  document.addEventListener('click',e=>{
    const nav=e.target.closest?.('[data-nav]');
    if(nav&&nav.dataset.nav!=='booking'){
      hideBar();
    }

    if(e.target.closest?.('#bookingBack')){
      setTimeout(enhance,0);
    }
  },true);

  function boot(){
    injectStyles();
    ensureBar();

    const stage=document.getElementById(STAGE_ID);
    if(!stage)return;

    if(stage.dataset.v1237Observed!=='1'){
      stage.dataset.v1237Observed='1';
      new MutationObserver(enhance).observe(stage,{childList:true,subtree:true});
    }

    const bookingView=document.querySelector('[data-view="booking"]');
    if(bookingView&&bookingView.dataset.v1238Observed!=='1'){
      bookingView.dataset.v1238Observed='1';
      new MutationObserver(enhance).observe(bookingView,{
        attributes:true,
        attributeFilter:['class']
      });
    }

    enhance();
  }

  if(document.readyState==='loading'){
    document.addEventListener('DOMContentLoaded',boot,{once:true});
  }else{
    boot();
  }

  setTimeout(boot,250);
  setTimeout(boot,800);
})();
