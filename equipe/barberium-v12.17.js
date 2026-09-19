// Barberium v12.17 — atualização automática do saldo em Contratos ativos.
// Cirúrgico: não altera consumo de créditos, planos, financeiro ou Supabase.
// Apenas força a tela já existente a buscar novamente o saldo quando volta a ficar visível.

(() => {
  let installed = false;
  let refreshTimer = null;
  let lastRefreshAt = 0;

  function contractsVisible() {
    const financePanel = document.querySelector('#financePanel');
    const plansTab = document.querySelector('#financePlansTab');
    const contractsTab = document.querySelector('#v129ContractsTab');
    return Boolean(
      financePanel &&
      plansTab &&
      contractsTab &&
      !financePanel.classList.contains('hidden') &&
      !plansTab.classList.contains('hidden') &&
      !contractsTab.classList.contains('hidden')
    );
  }

  function refreshContracts(reason = 'visibility') {
    clearTimeout(refreshTimer);
    refreshTimer = setTimeout(() => {
      if (!contractsVisible()) return;

      // Evita chamadas duplicadas causadas pelo mesmo ciclo de classes/DOM.
      const now = Date.now();
      if (now - lastRefreshAt < 350) return;
      lastRefreshAt = now;

      const button = document.querySelector('[data-v129-plan-mode="contracts"]');
      if (button) button.click();
    }, 120);
  }

  function install() {
    if (installed) return;

    const financePanel = document.querySelector('#financePanel');
    const plansTab = document.querySelector('#financePlansTab');
    if (!financePanel || !plansTab) return;

    installed = true;

    // Quando volta para Financeiro ou para a aba Planos.
    const observer = new MutationObserver(() => refreshContracts('visibility'));
    observer.observe(financePanel, { attributes: true, attributeFilter: ['class'] });
    observer.observe(plansTab, { attributes: true, attributeFilter: ['class'] });

    // Cliques de navegação: cobre também situações em que a classe já estava no mesmo estado.
    document.addEventListener('click', event => {
      if (
        event.target.closest('[data-team-panel="finance"]') ||
        event.target.closest('[data-finance-tab="plans"]') ||
        event.target.closest('[data-v129-plan-mode="contracts"]')
      ) {
        refreshContracts('click');
      }
    }, true);

    // Se o navegador/app volta do segundo plano com Contratos ativos aberto,
    // atualiza o saldo em vez de manter o snapshot antigo.
    document.addEventListener('visibilitychange', () => {
      if (!document.hidden) refreshContracts('visibilitychange');
    });
    window.addEventListener('focus', () => refreshContracts('focus'));

    refreshContracts('install');
  }

  // v12.9 injeta "Contratos ativos" dinamicamente; esperamos sem tocar na lógica dela.
  const bootObserver = new MutationObserver(() => {
    if (document.querySelector('#financePlansTab') && document.querySelector('[data-v129-plan-mode="contracts"]')) {
      install();
      bootObserver.disconnect();
    }
  });
  bootObserver.observe(document.documentElement, { childList: true, subtree: true });

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', install, { once: true });
  } else {
    install();
  }

  setTimeout(install, 500);
  setTimeout(install, 1500);
})();

/* v12.20 · barbeiro fecha comanda usando ficha de plano */
(() => {
  const SUPABASE_URL='https://pmvvawbaqylspxfmxezw.supabase.co';
  const SUPABASE_KEY='sb_publishable_CveglntZGjChE89lPcsQcg_EvBnYmKo';
  const AUTH_KEY='barberium_staff_auth_v1';
  const $=(s,r=document)=>r.querySelector(s);
  const $$=(s,r=document)=>[...r.querySelectorAll(s)];
  const esc=(v='')=>String(v).replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#039;'}[c]));
  const money=n=>new Intl.NumberFormat('pt-BR',{style:'currency',currency:'BRL'}).format((Number(n)||0)/100);
  const previousFetch=window.fetch.bind(window);
  let lastAppointmentId=null,injecting=false,observer=null;

  function getAuth(){try{return JSON.parse(localStorage.getItem(AUTH_KEY)||'null')}catch{return null}}
  function saveAuth(v){localStorage.setItem(AUTH_KEY,JSON.stringify(v))}
  async function authFetch(path,opts={}){
    const session=getAuth();
    const headers={apikey:SUPABASE_KEY,'Content-Type':'application/json',...(opts.headers||{})};
    if(session?.access_token)headers.Authorization=`Bearer ${session.access_token}`;
    let r=await previousFetch(`${SUPABASE_URL}${path}`,{...opts,headers});
    if(r.status===401&&session?.refresh_token){
      const rr=await previousFetch(`${SUPABASE_URL}/auth/v1/token?grant_type=refresh_token`,{method:'POST',headers:{apikey:SUPABASE_KEY,'Content-Type':'application/json'},body:JSON.stringify({refresh_token:session.refresh_token})});
      if(rr.ok){const refreshed=await rr.json();saveAuth(refreshed);headers.Authorization=`Bearer ${refreshed.access_token}`;r=await previousFetch(`${SUPABASE_URL}${path}`,{...opts,headers})}
    }
    const text=await r.text();let data=null;try{data=text?JSON.parse(text):null}catch{data=text}
    if(!r.ok)throw new Error(data?.message||data?.msg||data?.error_description||data?.error||`Erro ${r.status}`);
    return data;
  }
  const rpc=(name,payload={})=>authFetch(`/rest/v1/rpc/${name}`,{method:'POST',body:JSON.stringify(payload)});
  function toast(msg){const t=$('#toast');if(!t)return;t.textContent=msg;t.classList.add('show');clearTimeout(toast.timer);toast.timer=setTimeout(()=>t.classList.remove('show'),3000)}

  window.fetch=async function(input,init={}){
    const url=typeof input==='string'?input:input?.url;
    const match=typeof url==='string'?url.match(/\/rest\/v1\/rpc\/(barberium_staff_appointment_detail|barberium_staff_appointment_finance)(?:\?|$)/):null;
    if(match&&init?.body){try{const body=typeof init.body==='string'?JSON.parse(init.body):init.body;if(body?.p_appointment_id)lastAppointmentId=body.p_appointment_id}catch{}}
    return previousFetch(input,init);
  };

  const useStatusLabel=status=>({reserved:'Ficha selecionada',consumed:'Ficha utilizada',forfeited:'Ficha consumida',decision_required:'Aguardando decisão'})[status]||status;
  function optionLabel(o){if(o.unlimited)return'Ilimitado';const n=Number(o.available)||0;return`${n} ficha${n===1?'':'s'} disponível${n===1?'':'is'}`}
  async function waitFor(selector,timeout=2600){const first=$(selector);if(first)return first;return new Promise(resolve=>{const started=Date.now();const timer=setInterval(()=>{const el=$(selector);if(el||Date.now()-started>timeout){clearInterval(timer);resolve(el||null)}},60)})}
  async function reopenCheckout(id){
    $('#modalClose')?.click();await new Promise(r=>setTimeout(r,120));
    const card=$(`[data-appt-id="${id}"]`);
    if(!card){toast('Ficha atualizada. Abra a comanda novamente para ver o novo valor.');return}
    card.click();const complete=await waitFor('[data-new-status="completed"]');
    if(!complete){toast('Ficha atualizada. Toque em Concluído novamente para continuar.');return}
    complete.click();
  }
  async function applyOption(id,o,button){
    button.disabled=true;button.textContent='Aplicando ficha…';
    try{
      await rpc('barberium_staff_reserve_membership_use',{p_appointment_id:id,p_membership_id:o.membership_id,p_benefit_id:o.benefit_id,p_bucket_id:o.bucket_id||null,p_target_service_id:o.target_service_id});
      toast('Ficha aplicada à comanda.');await reopenCheckout(id);
    }catch(e){toast(e?.message||'Não foi possível aplicar a ficha.');button.disabled=false;button.textContent='Usar ficha'}
  }
  async function releaseUse(id,use,button){
    button.disabled=true;button.textContent='Removendo…';
    try{await rpc('barberium_staff_release_membership_use',{p_use_id:use.id});toast('Ficha removida desta comanda.');await reopenCheckout(id)}
    catch(e){toast(e?.message||'Não foi possível remover a ficha.');button.disabled=false;button.textContent='Não usar esta ficha'}
  }
  function planBoxHtml(ctx,fin){
    const options=ctx?.options||[];
    const activeUses=(fin?.uses||[]).filter(u=>['reserved','consumed','forfeited','decision_required'].includes(u.status));
    const planNames=[...new Set((ctx?.plans||[]).map(p=>p.plan).filter(Boolean))];
    const usesHtml=activeUses.map(u=>`<article class="service-stat v1220-use-card"><div><h3>${esc(u.plan)} • ${esc(u.service)}</h3><p>${esc(useStatusLabel(u.status))} • cobre ${money(u.coverage_cents)}</p></div>${u.status==='reserved'?`<button class="soft-btn small" data-v1220-release="${u.id}" type="button">Não usar esta ficha</button>`:''}</article>`).join('');
    const optionsHtml=options.map((o,i)=>`<article class="service-stat v1220-option-card"><div><h3>${esc(o.target_service)}</h3><p>${esc(o.plan)} • ${esc(o.covered_service)} • ${esc(optionLabel(o))}</p><p>Abatimento nesta comanda: <strong>${money(o.coverage_cents)}</strong></p></div><button class="gold-btn small" data-v1220-option="${i}" type="button">Usar ficha</button></article>`).join('');
    const none=!activeUses.length&&!options.length?'<div class="empty">Este cliente possui plano, mas não há ficha disponível ou aplicável aos serviços desta comanda.</div>':'';
    return `<section id="v1220MembershipCheckout"><div class="detail-note"><small>CLIENTE DE PLANO</small><p>${planNames.length?esc(planNames.join(' • ')):'Plano ativo'} — escolha abaixo se este atendimento será abatido por ficha.</p></div>${usesHtml}${optionsHtml}${none}</section>`;
  }
  async function inject(){
    if(injecting)return;const root=$('#modalBody');
    if(!root||!$('#finishAppointmentPayment',root)||$('#v1220MembershipCheckout',root)||!lastAppointmentId)return;
    injecting=true;const id=lastAppointmentId;
    try{
      const [ctx,fin]=await Promise.all([rpc('barberium_staff_checkout_membership_context',{p_appointment_id:id}),rpc('barberium_staff_appointment_finance',{p_appointment_id:id})]);
      if(!ctx?.has_plan||!$('#finishAppointmentPayment',root)||$('#v1220MembershipCheckout',root))return;
      const wrap=document.createElement('div');wrap.innerHTML=planBoxHtml(ctx,fin);const section=wrap.firstElementChild;
      const firstFinancial=root.querySelector('.detail-note,.detail-grid');if(firstFinancial)root.insertBefore(section,firstFinancial);else root.prepend(section);
      $$('[data-v1220-option]',section).forEach(btn=>{const o=(ctx.options||[])[Number(btn.dataset.v1220Option)];if(o)btn.onclick=()=>applyOption(id,o,btn)});
      $$('[data-v1220-release]',section).forEach(btn=>{const use=(fin.uses||[]).find(u=>u.id===btn.dataset.v1220Release);if(use)btn.onclick=()=>releaseUse(id,use,btn)});
    }catch(e){console.error('Barberium v12.20 plano na comanda:',e)}finally{injecting=false}
  }
  function boot(){const modal=$('#modalBody');if(!modal||observer)return;observer=new MutationObserver(()=>setTimeout(inject,40));observer.observe(modal,{childList:true,subtree:true});inject()}
  if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',boot);else boot();
  setTimeout(boot,600);
})();

/* v12.21 · cliente passageiro em Novo horário / Novo encaixe */
(() => {
  const $=(s,r=document)=>r.querySelector(s);
  const $$=(s,r=document)=>[...r.querySelectorAll(s)];
  const previousFetch21=window.fetch.bind(window);
  let observer21=null;

  function passengerForm(){
    const form=$('#bookingForm');
    return form?.dataset.v1221Passenger==='1' ? form : null;
  }

  function extraServiceIds(){
    return $$('[data-v1212-remove-service]')
      .map(btn=>btn.dataset.v1212RemoveService)
      .filter(Boolean);
  }

  window.fetch=async function(input,init={}){
    const url=typeof input==='string'?input:input?.url;
    const match=typeof url==='string'
      ?url.match(/\/rest\/v1\/rpc\/(barberium_staff_create_appointment|barberium_staff_create_walk_in)(?:\?|$)/)
      :null;

    const form=passengerForm();
    if(match&&form&&init?.body){
      try{
        const body=typeof init.body==='string'?JSON.parse(init.body):{...(init.body||{})};
        const target=match[1]==='barberium_staff_create_walk_in'
          ?'barberium_staff_create_walk_in_v12_21'
          :'barberium_staff_create_appointment_v12_21';

        const patched={
          ...body,
          p_customer_id:null,
          p_full_name:null,
          p_phone:null,
          p_extra_service_ids:extraServiceIds(),
          p_is_passenger:true
        };

        const nextUrl=url.replace(`/rpc/${match[1]}`,`/rpc/${target}`);
        return previousFetch21(nextUrl,{...init,body:JSON.stringify(patched)});
      }catch(e){
        console.error('Barberium v12.21 passageiro:',e);
      }
    }

    return previousFetch21(input,init);
  };

  function setPassenger(form,on){
    const search=$('#customerSearch',form);
    const searchField=search?.closest('.field');
    const normalActions=$('#searchCustomerButton',form)?.closest('.action-row');
    const newFields=$('#newCustomerFields',form);
    const selected=$('#selectedCustomerWrap',form);
    const results=$('#customerResults',form);
    const name=$('#newCustomerName',form);
    const phone=$('#newCustomerPhone',form);
    const button=$('#v1221PassengerButton',form);

    form.dataset.v1221Passenger=on?'1':'0';

    if(on){
      // Aciona o fluxo "novo cliente" já existente apenas para ajustar o estado
      // interno do team.js. O request será redirecionado ao RPC passageiro.
      $('#newCustomerButton',form)?.click();

      if(name)name.value='Cliente passageiro';
      if(phone)phone.value='';
      if(search)search.value='';
      if(results)results.innerHTML='';

      searchField?.classList.add('hidden');
      normalActions?.classList.add('hidden');
      newFields?.classList.add('hidden');

      if(selected)selected.innerHTML=`
        <div class="selected-customer">
          <strong>Cliente passageiro</strong>
          <small>Sem nome, WhatsApp ou cadastro na base de clientes</small>
        </div>`;

      if(button)button.textContent='Usar cliente identificado';
    }else{
      searchField?.classList.remove('hidden');
      normalActions?.classList.remove('hidden');
      newFields?.classList.add('hidden');

      if(name)name.value='';
      if(phone)phone.value='';
      if(selected)selected.innerHTML='';
      if(results)results.innerHTML='';
      if(button)button.textContent='Cliente passageiro';
    }
  }

  function injectPassenger(){
    const form=$('#bookingForm');
    if(!form||form.dataset.v1221Ready==='1')return;

    // Em edição o cliente do atendimento já existe; o recurso é para registrar
    // novos horários/encaixes esquecidos ou sem identificação.
    const newCustomer=$('#newCustomerButton',form);
    const actionRow=newCustomer?.closest('.action-row');
    if(!newCustomer||!actionRow)return;

    form.dataset.v1221Ready='1';
    form.dataset.v1221Passenger='0';

    const wrap=document.createElement('div');
    wrap.id='v1221PassengerWrap';
    wrap.className='action-row';
    wrap.innerHTML=`
      <button id="v1221PassengerButton" class="soft-btn" type="button">
        Cliente passageiro
      </button>
      <small style="align-self:center;opacity:.72">
        Use quando não houver nome ou WhatsApp do cliente.
      </small>
    `;
    actionRow.insertAdjacentElement('afterend',wrap);

    $('#v1221PassengerButton',form).onclick=()=>{
      const active=form.dataset.v1221Passenger==='1';
      setPassenger(form,!active);
    };
  }

  function boot21(){
    const modal=$('#modalBody');
    if(!modal||observer21)return;
    observer21=new MutationObserver(()=>setTimeout(injectPassenger,20));
    observer21.observe(modal,{childList:true,subtree:true});
    injectPassenger();
  }

  if(document.readyState==='loading'){
    document.addEventListener('DOMContentLoaded',boot21);
  }else{
    boot21();
  }
  setTimeout(boot21,500);
})();

