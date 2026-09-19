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

/* v12.22 · valores decimais da comissão de planos aceitam ponto ou vírgula */
(() => {
  function normalizePlanCommissionMoney(value){
    const s=String(value??'').trim();
    if(!s || s.includes(',')) return s;
    const dots=(s.match(/\./g)||[]).length;
    if(dots!==1) return s;
    const parts=s.split('.');
    const left=parts[0],right=parts[1];
    if(!/^-?\d+$/.test(left) || !/^\d{1,2}$/.test(right)) return s;
    return `${left},${right}`;
  }

  function normalizeTarget(input){
    if(!input) return;
    const next=normalizePlanCommissionMoney(input.value);
    if(next!==input.value) input.value=next;
  }

  document.addEventListener('blur', event => {
    const input=event.target;
    if(!(input instanceof HTMLInputElement)) return;
    if(input.matches('[data-plan-commission-service],#planHourlyRate')) normalizeTarget(input);
  }, true);

  // Capture roda antes do onsubmit do team.js. Assim, 25.50 chega ao parser
  // original como 25,50, sem alterar nenhuma outra lógica financeira.
  document.addEventListener('submit', event => {
    if(event.target?.id!=='planForm') return;
    const type=document.querySelector('#planCommissionType')?.value;
    if(type==='attendance'){
      document.querySelectorAll('[data-plan-commission-service]').forEach(normalizeTarget);
    }else if(type==='hour'){
      normalizeTarget(document.querySelector('#planHourlyRate'));
    }
  }, true);
})();

/* v12.23 · cancelamento concluído separa anulação operacional de reembolso real */
(() => {
  const SUPABASE_URL='https://pmvvawbaqylspxfmxezw.supabase.co';
  const SUPABASE_KEY='sb_publishable_CveglntZGjChE89lPcsQcg_EvBnYmKo';
  const AUTH_KEY='barberium_staff_auth_v1';
  const $=(s,r=document)=>r.querySelector(s);
  const money=n=>new Intl.NumberFormat('pt-BR',{style:'currency',currency:'BRL'}).format((Number(n)||0)/100);
  const esc=(v='')=>String(v).replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#039;'}[c]));

  let lastAppointmentId=new URLSearchParams(location.search).get('appointment')||null;
  let opening=false;

  function getAuth(){
    try{return JSON.parse(localStorage.getItem(AUTH_KEY)||'null')}catch{return null}
  }
  function saveAuth(v){localStorage.setItem(AUTH_KEY,JSON.stringify(v))}
  async function authFetch(path,opts={}){
    const session=getAuth();
    const headers={apikey:SUPABASE_KEY,'Content-Type':'application/json',...(opts.headers||{})};
    if(session?.access_token)headers.Authorization=`Bearer ${session.access_token}`;
    let r=await fetch(`${SUPABASE_URL}${path}`,{...opts,headers});
    if(r.status===401&&session?.refresh_token){
      const rr=await fetch(`${SUPABASE_URL}/auth/v1/token?grant_type=refresh_token`,{
        method:'POST',
        headers:{apikey:SUPABASE_KEY,'Content-Type':'application/json'},
        body:JSON.stringify({refresh_token:session.refresh_token})
      });
      if(rr.ok){
        const refreshed=await rr.json();
        saveAuth(refreshed);
        headers.Authorization=`Bearer ${refreshed.access_token}`;
        r=await fetch(`${SUPABASE_URL}${path}`,{...opts,headers});
      }
    }
    const text=await r.text();
    let data=null;try{data=text?JSON.parse(text):null}catch{data=text}
    if(!r.ok)throw new Error(data?.message||data?.msg||data?.error_description||data?.error||`Erro ${r.status}`);
    return data;
  }
  const rpc=(name,payload={})=>authFetch(`/rest/v1/rpc/${name}`,{
    method:'POST',
    body:JSON.stringify(payload)
  });

  function toast(msg){
    const t=$('#toast');
    if(!t)return;
    t.textContent=msg;
    t.classList.add('show');
    clearTimeout(toast.timer);
    toast.timer=setTimeout(()=>t.classList.remove('show'),3000);
  }

  function openModal(eyebrow,title,html){
    const back=$('#modalBackdrop');
    if(!back)return;
    $('#modalEyebrow').textContent=eyebrow||'';
    $('#modalTitle').textContent=title||'';
    $('#modalBody').innerHTML=html;
    back.classList.remove('hidden');
    back.setAttribute('aria-hidden','false');
  }

  function closeModal(){
    const back=$('#modalBackdrop');
    if(!back)return;
    back.classList.add('hidden');
    back.setAttribute('aria-hidden','true');
    $('#modalBody').innerHTML='';
  }

  function refreshAgenda(){
    const input=$('#dateInput');
    if(input?.value)input.dispatchEvent(new Event('change',{bubbles:true}));
  }

  async function openCompletedCancellation(id){
    if(opening)return;
    opening=true;
    openModal(
      'CANCELAR ATENDIMENTO CONCLUÍDO',
      'Conferir cancelamento',
      '<div class="loading">Conferindo pagamentos e produtos…</div>'
    );

    try{
      const [d,f,p]=await Promise.all([
        rpc('barberium_staff_appointment_detail',{p_appointment_id:id}),
        rpc('barberium_staff_appointment_finance',{p_appointment_id:id}),
        rpc('barberium_staff_appointment_products',{p_appointment_id:id})
      ]);

      const servicePaid=Math.max(0,Number(f.paid_cents||0)-Number(f.refunds_cents||0));
      const productPaid=p.status==='completed'?Number(p.paid_cents||0):0;
      const pending=Number(f.receivable?.remaining_cents||0)+(p.status==='completed'?Number(p.pending_cents||0):0);
      const hasMembership=(f.uses||[]).some(u=>u.status==='consumed');

      openModal('CANCELAR ATENDIMENTO CONCLUÍDO',d.customer?.name||'Atendimento',`
        <form id="v1223CancelCompletedForm" class="form-grid">
          <div class="detail-grid">
            <div class="detail-box">
              <small>Valor registrado no serviço</small>
              <strong>${money(servicePaid)}</strong>
            </div>
            <div class="detail-box">
              <small>Valor registrado em produtos</small>
              <strong>${money(productPaid)}</strong>
            </div>
            <div class="detail-box wide">
              <small>Total registrado na comanda</small>
              <strong>${money(servicePaid+productPaid)}</strong>
            </div>
          </div>

          <div class="field">
            <label>Tipo do cancelamento</label>
            <select id="v1223CancellationKind">
              <option value="booking_error">Engano / erro operacional</option>
              <option value="regular">Cancelamento normal</option>
            </select>
          </div>

          <label class="check-row">
            <input id="v1223IsRefund" type="checkbox">
            <span>ISTO FOI REEMBOLSO</span>
          </label>

          <p class="v128-cancel-help">
            Marque somente se o dinheiro realmente entrou e depois foi devolvido ao cliente.
            Se foi erro de lançamento/agendamento e o dinheiro nunca entrou, deixe desmarcado.
          </p>

          <div id="v1223NoRefundNote" class="detail-note">
            <p><strong>Sem reembolso:</strong> o Barberium vai anular os recebimentos registrados por engano.
            Eles não aparecerão como faturamento nem como reembolso.</p>
          </div>

          <div id="v1223RefundNote" class="detail-note hidden">
            <p><strong>Com reembolso:</strong> o recebimento permanece no histórico e a devolução entra
            no Financeiro como reembolso real.</p>
          </div>

          <div id="v1223RefundMethodWrap" class="field hidden">
            <label>Forma da devolução</label>
            <select id="v1223RefundMethod">
              <option value="">Selecione</option>
              <option value="pix">Pix</option>
              <option value="cash">Dinheiro</option>
              <option value="debit">Débito</option>
              <option value="credit">Crédito</option>
              <option value="transfer">Transferência</option>
              <option value="other">Outro</option>
            </select>
          </div>

          <div class="detail-note">
            <p>O cancelamento reverte as comissões e devolve produtos ao estoque.
            ${pending>0?` O saldo pendente de ${money(pending)} será cancelado.`:''}
            ${hasMembership?' A ficha do plano/pacote será devolvida.':''}</p>
          </div>

          <div class="field">
            <label>Motivo do cancelamento</label>
            <textarea id="v1223Reason" minlength="3" required
              placeholder="Ex.: atendimento lançado por engano"></textarea>
          </div>

          <button id="v1223ConfirmCancel" class="danger-btn finance-wide" type="submit">
            Cancelar sem registrar reembolso
          </button>
        </form>
      `);

      const form=$('#v1223CancelCompletedForm');
      const isRefund=$('#v1223IsRefund');
      const refundWrap=$('#v1223RefundMethodWrap');
      const refundMethod=$('#v1223RefundMethod');
      const noRefundNote=$('#v1223NoRefundNote');
      const refundNote=$('#v1223RefundNote');
      const button=$('#v1223ConfirmCancel');

      const sync=()=>{
        const on=isRefund.checked;
        refundWrap.classList.toggle('hidden',!on);
        noRefundNote.classList.toggle('hidden',on);
        refundNote.classList.toggle('hidden',!on);
        refundMethod.required=on;
        button.textContent=on
          ?'Cancelar e registrar reembolso'
          :'Cancelar sem registrar reembolso';
      };
      isRefund.addEventListener('change',sync);
      sync();

      form.onsubmit=async e=>{
        e.preventDefault();
        if(button.disabled)return;

        const refund=isRefund.checked;
        const method=refund?refundMethod.value:null;
        if(refund&&!method){
          toast('Selecione a forma da devolução.');
          return;
        }

        button.disabled=true;
        const oldText=button.textContent;
        button.textContent='Cancelando…';

        try{
          await rpc('barberium_staff_cancel_completed_appointment_v12_23',{
            p_appointment_id:id,
            p_reason:$('#v1223Reason').value.trim(),
            p_cancellation_kind:$('#v1223CancellationKind').value,
            p_is_refund:refund,
            p_refund_method:method
          });

          toast(refund
            ?'Atendimento cancelado e reembolso registrado.'
            :'Atendimento cancelado sem reembolso. Lançamentos incorretos foram anulados.'
          );
          closeModal();
          refreshAgenda();
        }catch(err){
          toast(err?.message||'Não foi possível cancelar.');
          button.disabled=false;
          button.textContent=oldText;
        }
      };
    }catch(err){
      const body=$('#modalBody');
      if(body)body.innerHTML=`<div class="empty">${esc(err?.message||'Não foi possível conferir o atendimento.')}</div>`;
    }finally{
      opening=false;
    }
  }

  // Window captura antes do listener antigo do documento.
  // Assim só substituímos o fluxo de "cancelar concluído", preservando todo o resto.
  window.addEventListener('click',event=>{
    const appointment=event.target.closest?.('[data-appt-id]');
    if(appointment?.dataset?.apptId)lastAppointmentId=appointment.dataset.apptId;

    const completedCancel=event.target.closest?.('#cancelCompletedAppointment');
    if(!completedCancel||!lastAppointmentId)return;

    event.preventDefault();
    event.stopPropagation();
    event.stopImmediatePropagation();
    openCompletedCancellation(lastAppointmentId);
  },true);
})();

