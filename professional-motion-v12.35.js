/* Barberium v12.35 · movimento premium dos profissionais
   Somente apresentação visual da etapa "Escolha o profissional".
*/
(() => {
  const STAGE_ID='bookingStage';
  const reduced=window.matchMedia?.('(prefers-reduced-motion: reduce)')?.matches===true;

  function injectStyles(){
    if(document.getElementById('barberiumProfessionalMotionV1235'))return;

    const style=document.createElement('style');
    style.id='barberiumProfessionalMotionV1235';
    style.textContent=`
      @keyframes v1235CardEnter{
        0%{
          opacity:0;
          transform:translateY(22px) scale(.965);
          filter:blur(2px);
        }
        70%{
          opacity:1;
          transform:translateY(-2px) scale(1.008);
          filter:blur(0);
        }
        100%{
          opacity:1;
          transform:translateY(0) scale(1);
          filter:blur(0);
        }
      }

      @keyframes v1235PortraitAlive{
        0%{
          transform:
            translate3d(calc(var(--mx,0px) - 1px),calc(var(--my,0px) + 1px),0)
            scale(1.045);
        }
        35%{
          transform:
            translate3d(calc(var(--mx,0px) + 1.5px),calc(var(--my,0px) - 1px),0)
            scale(1.105);
        }
        70%{
          transform:
            translate3d(calc(var(--mx,0px) - .5px),calc(var(--my,0px) - 2px),0)
            scale(1.075);
        }
        100%{
          transform:
            translate3d(calc(var(--mx,0px) - 1px),calc(var(--my,0px) + 1px),0)
            scale(1.045);
        }
      }

      @keyframes v1235SelectedPulse{
        0%{transform:translateY(0) scale(1)}
        45%{transform:translateY(-5px) scale(1.035)}
        72%{transform:translateY(-2px) scale(1.018)}
        100%{transform:translateY(-3px) scale(1.025)}
      }

      @keyframes v1235GlowSweep{
        0%,72%{transform:translateX(-170%) rotate(14deg);opacity:0}
        76%{opacity:.04}
        88%{opacity:.12}
        100%{transform:translateX(250%) rotate(14deg);opacity:0}
      }

      #${STAGE_ID} .pro-choice{
        position:relative;
        overflow:hidden;
        isolation:isolate;
        transform:translateZ(0);
        transition:
          transform .24s cubic-bezier(.2,.75,.25,1),
          border-color .24s ease,
          background .24s ease,
          box-shadow .24s ease;
      }

      #${STAGE_ID} .pro-choice::after{
        content:"";
        position:absolute;
        z-index:0;
        top:-60%;
        bottom:-60%;
        width:28%;
        left:0;
        pointer-events:none;
        background:linear-gradient(
          90deg,
          transparent,
          rgba(255,239,190,.8),
          transparent
        );
        animation:v1235GlowSweep 7s ease-in-out infinite;
      }

      #${STAGE_ID} .pro-choice > *{
        position:relative;
        z-index:1;
      }

      #${STAGE_ID} .pro-choice.v1235-enter{
        opacity:0;
        animation:v1235CardEnter .62s cubic-bezier(.16,.82,.24,1) forwards;
        animation-delay:var(--delay,0ms);
      }

      #${STAGE_ID} .pro-choice img{
        transform-origin:50% 42%;
        will-change:transform;
        animation:v1235PortraitAlive 5.8s ease-in-out infinite;
        animation-delay:var(--portrait-delay,0ms);
        transition:filter .25s ease,box-shadow .25s ease;
      }

      #${STAGE_ID} .pro-choice.selected{
        transform:translateY(-3px) scale(1.025);
        border-color:rgba(226,186,99,.8);
        background:#11271b;
        box-shadow:
          0 16px 34px rgba(0,0,0,.30),
          0 0 0 1px rgba(226,186,99,.15);
      }

      #${STAGE_ID} .pro-choice.selected.v1235-pop{
        animation:v1235SelectedPulse .34s cubic-bezier(.2,.9,.3,1) both;
      }

      #${STAGE_ID} .pro-choice.selected img{
        filter:brightness(1.07) contrast(1.025);
      }

      @media (hover:hover) and (pointer:fine){
        #${STAGE_ID} .pro-choice:hover{
          transform:translateY(-3px) scale(1.018);
          border-color:rgba(226,186,99,.48);
          box-shadow:0 14px 30px rgba(0,0,0,.24);
        }
      }

      @media (prefers-reduced-motion:reduce){
        #${STAGE_ID} .pro-choice,
        #${STAGE_ID} .pro-choice.v1235-enter,
        #${STAGE_ID} .pro-choice.selected.v1235-pop,
        #${STAGE_ID} .pro-choice img,
        #${STAGE_ID} .pro-choice::after{
          animation:none!important;
          transition:none!important;
          opacity:1!important;
          filter:none!important;
          transform:none!important;
        }
      }
    `;
    document.head.appendChild(style);
  }

  function resetPortrait(card){
    const img=card.querySelector('img');
    if(!img)return;
    img.style.setProperty('--mx','0px');
    img.style.setProperty('--my','0px');
  }

  function bind(card){
    if(card.dataset.v1235Bound==='1')return;
    card.dataset.v1235Bound='1';

    const img=card.querySelector('img');
    if(!img)return;

    card.addEventListener('pointermove',e=>{
      if(reduced)return;
      const r=card.getBoundingClientRect();
      const x=((e.clientX-r.left)/r.width-.5);
      const y=((e.clientY-r.top)/r.height-.5);
      const factor=e.pointerType==='mouse'?5:3;
      img.style.setProperty('--mx',`${(x*factor).toFixed(2)}px`);
      img.style.setProperty('--my',`${(y*factor*.65).toFixed(2)}px`);
    },{passive:true});

    card.addEventListener('pointerleave',()=>resetPortrait(card));

    card.addEventListener('pointerdown',e=>{
      if(reduced)return;
      const r=card.getBoundingClientRect();
      const x=((e.clientX-r.left)/r.width-.5);
      const y=((e.clientY-r.top)/r.height-.5);
      img.style.setProperty('--mx',`${(x*3.4).toFixed(2)}px`);
      img.style.setProperty('--my',`${(y*2.2).toFixed(2)}px`);
    },{passive:true});
  }

  let lastSelectedId=null;
  let screenGeneration=0;

  document.addEventListener('pointerdown',e=>{
    const card=e.target.closest?.(`#${STAGE_ID} .pro-choice`);
    if(card)lastSelectedId=card.dataset.pro||null;
  },true);

  function enhance(){
    const stage=document.getElementById(STAGE_ID);
    if(!stage)return;

    const cards=[...stage.querySelectorAll('.pro-choice')];

    if(!cards.length){
      stage.dataset.v1235Screen='';
      return;
    }

    const markupKey=cards.map(c=>c.dataset.pro||'').join('|');
    const firstRender=stage.dataset.v1235Screen!==markupKey;

    if(firstRender){
      stage.dataset.v1235Screen=markupKey;
      screenGeneration++;

      cards.forEach((card,i)=>{
        card.classList.remove('v1235-enter','v1235-pop');
        card.style.setProperty('--delay',`${i*105}ms`);
        card.style.setProperty('--portrait-delay',`${-(i*1300)}ms`);

        if(!reduced){
          requestAnimationFrame(()=>{
            card.classList.add('v1235-enter');
          });
        }
      });
    }

    cards.forEach(card=>{
      bind(card);

      if(
        !reduced &&
        lastSelectedId &&
        card.dataset.pro===lastSelectedId &&
        card.classList.contains('selected')
      ){
        card.classList.remove('v1235-pop');
        void card.offsetWidth;
        card.classList.add('v1235-pop');
        setTimeout(()=>card.classList.remove('v1235-pop'),400);
      }
    });

    lastSelectedId=null;
  }

  function boot(){
    injectStyles();

    const stage=document.getElementById(STAGE_ID);
    if(!stage)return;

    if(stage.dataset.v1235Observer!=='1'){
      stage.dataset.v1235Observer='1';
      new MutationObserver(enhance).observe(stage,{
        childList:true,
        subtree:true
      });
    }

    enhance();
  }

  if(document.readyState==='loading'){
    document.addEventListener('DOMContentLoaded',boot,{once:true});
  }else{
    boot();
  }

  setTimeout(boot,300);
  setTimeout(boot,900);
})();
