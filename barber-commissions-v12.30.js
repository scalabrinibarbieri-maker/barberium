/* Barberium v12.31 · correção definitiva do travamento em "Minhas comissões"
   Causa: MutationObserver antigo da v12.8 reescrevia o mesmo texto infinitamente.
   Correção: desacopla o observer antigo de #commissionContent e instala uma versão idempotente.
   Não altera cálculo, RPC, permissões, financeiro do ADM ou Supabase.
*/
(() => {
  const $=(s,r=document)=>r.querySelector(s);
  const $$=(s,r=document)=>[...r.querySelectorAll(s)];

  function cleanCommissionSummary(root){
    if(!root)return;

    for(const card of $$('.service-stat',root)){
      const h=card.querySelector('h3');
      if(!h)continue;

      const m=String(h.textContent||'').match(
        /Cancelamentos?\s+por\s+erro\s+de\s+agendamento:\s*(\d+)/i
      );
      if(!m)continue;

      const wanted=`Cancelamento por erro de agendamento: ${m[1]}`;

      // ESSENCIAL: só altera o DOM se houver mudança real.
      // Isso impede o MutationObserver de entrar em recursão infinita.
      if(h.textContent!==wanted)h.textContent=wanted;

      const p=card.querySelector('p');
      if(p&&p.style.display!=='none')p.style.display='none';

      const strong=card.querySelector(':scope > strong');
      if(strong&&strong.style.display!=='none')strong.style.display='none';
    }
  }

  function install(){
    const oldRoot=$('#commissionContent');
    if(!oldRoot||oldRoot.dataset.v1231Fixed==='1')return;

    /*
      O observer defeituoso da v12.8 já está ligado ao elemento antigo.
      MutationObserver não pode ser removido sem sua referência.
      Substituir o nó por um clone desconecta definitivamente aquele observer.
    */
    const root=oldRoot.cloneNode(true);

    // Impede os boot timers da v12.8 de recolocarem o observer antigo.
    root.dataset.v128Observed='1';
    root.dataset.v1231Fixed='1';

    oldRoot.replaceWith(root);

    const observer=new MutationObserver(()=>{
      cleanCommissionSummary(root);
    });

    observer.observe(root,{
      childList:true,
      subtree:true
    });

    cleanCommissionSummary(root);
  }

  // Os módulos são deferidos; normalmente o DOM já existe aqui.
  install();

  // Fallbacks sem efeito colateral caso a ordem de execução varie.
  if(document.readyState==='loading'){
    document.addEventListener('DOMContentLoaded',install,{once:true});
  }
  setTimeout(install,100);
  setTimeout(install,500);
})();
