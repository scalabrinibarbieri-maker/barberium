// Barberium v12.9 — correções cirúrgicas de Planos, créditos, Agenda/Cancelados e entradas numéricas.
const V129_SUPABASE_URL='https://pmvvawbaqylspxfmxezw.supabase.co';
const V129_SUPABASE_KEY='sb_publishable_CveglntZGjChE89lPcsQcg_EvBnYmKo';
const V129_AUTH_KEY='barberium_staff_auth_v1';

const v129$=(s,r=document)=>r.querySelector(s);
const v129$$=(s,r=document)=>[...r.querySelectorAll(s)];
const v129Esc=(v='')=>String(v).replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#039;'}[c]));
let v129Contracts=[];
let v129PlanMode='catalog';

function v129GetAuth(){try{return JSON.parse(localStorage.getItem(V129_AUTH_KEY)||'null')}catch{return null}}
function v129SaveAuth(v){localStorage.setItem(V129_AUTH_KEY,JSON.stringify(v))}
async function v129AuthFetch(path,opts={}){
  const session=v129GetAuth();
  const headers={apikey:V129_SUPABASE_KEY,'Content-Type':'application/json',...(opts.headers||{})};
  if(session?.access_token)headers.Authorization=`Bearer ${session.access_token}`;
  let r=await fetch(`${V129_SUPABASE_URL}${path}`,{...opts,headers});
  if(r.status===401&&session?.refresh_token){
    const rr=await fetch(`${V129_SUPABASE_URL}/auth/v1/token?grant_type=refresh_token`,{
      method:'POST',
      headers:{apikey:V129_SUPABASE_KEY,'Content-Type':'application/json'},
      body:JSON.stringify({refresh_token:session.refresh_token})
    });
    if(rr.ok){
      const refreshed=await rr.json();
      v129SaveAuth(refreshed);
      headers.Authorization=`Bearer ${refreshed.access_token}`;
      r=await fetch(`${V129_SUPABASE_URL}${path}`,{...opts,headers});
    }
  }
  const text=await r.text();
  let data=null;try{data=text?JSON.parse(text):null}catch{data=text}
  if(!r.ok)throw new Error(data?.message||data?.msg||data?.error_description||data?.error||`Erro ${r.status}`);
  return data;
}
async function v129Rpc(name,payload={}){
  return v129AuthFetch(`/rest/v1/rpc/${name}`,{method:'POST',body:JSON.stringify(payload)});
}
function v129Toast(msg){
  const e=v129$('#toast');
  if(!e)return;
  e.textContent=msg;
  e.classList.add('show');
  clearTimeout(v129Toast.t);
  v129Toast.t=setTimeout(()=>e.classList.remove('show'),2800);
}
function v129OpenModal(eyebrow,title,html){
  const back=v129$('#modalBackdrop');
  if(!back)return;
  v129$('#modalEyebrow').textContent=eyebrow||'';
  v129$('#modalTitle').textContent=title||'';
  v129$('#modalBody').innerHTML=html;
  back.classList.remove('hidden');
  back.setAttribute('aria-hidden','false');
}
function v129CloseModal(){
  const back=v129$('#modalBackdrop');
  if(!back)return;
  back.classList.add('hidden');
  back.setAttribute('aria-hidden','true');
  v129$('#modalBody').innerHTML='';
}
function v129Money(cents){
  return new Intl.NumberFormat('pt-BR',{style:'currency',currency:'BRL'}).format((Number(cents)||0)/100);
}
function v129DateTime(value){
  if(!value)return'—';
  return new Intl.DateTimeFormat('pt-BR',{timeZone:'America/Sao_Paulo',day:'2-digit',month:'2-digit',year:'numeric',hour:'2-digit',minute:'2-digit'}).format(new Date(value));
}
function v129Date(value){
  if(!value)return'—';
  const s=String(value).slice(0,10);
  const [y,m,d]=s.split('-');
  return y&&m&&d?`${d}/${m}/${y}`:s;
}
function v129Status(v){
  return ({active:'Ativa',pending:'Pendente',paused:'Pausada',overdue:'Atrasada',cancelled:'Cancelada',expired:'Vencida'})[v]||v||'—';
}
function v129MoneyToCents(v){
  let s=String(v??'').trim().replace(/[^\d,.-]/g,'');
  if(s.includes(','))s=s.replace(/\./g,'').replace(',','.');
  const n=Number(s);
  return Number.isFinite(n)?Math.round(n*100):0;
}

function v129InjectFixStyle(){
  if(v129$('#barberiumV129Style'))return;
  const style=document.createElement('style');
  style.id='barberiumV129Style';
  style.textContent=`
    #agendaList .agenda-item[hidden]{display:none!important}
    #v129PlanTabs{margin:0 0 14px}
    #v129ContractsTab .client-search{margin:12px 0}
    .v129-contract-summary{display:grid;gap:8px}
    .v129-contract-customer{font:600 18px Georgia,"Times New Roman",serif;margin:0}
    .v129-contract-actions{display:flex;gap:7px;flex-wrap:wrap;margin-top:10px}
    .v129-contract-actions>*{flex:1 1 140px}
  `;
  document.head.appendChild(style);
}

function v129IsNumericInput(input){
  return input instanceof HTMLInputElement &&
    (input.type==='number'||input.inputMode==='decimal'||input.inputMode==='numeric');
}
function v129IsZeroLike(input){
  if(!v129IsNumericInput(input))return false;
  const raw=String(input.value||'').trim().replace(',','.');
  return raw!==''&&Number.isFinite(Number(raw))&&Number(raw)===0;
}
document.addEventListener('focusin',e=>{
  const input=e.target;
  if(!v129IsZeroLike(input))return;
  requestAnimationFrame(()=>{try{input.select()}catch{}});
});
document.addEventListener('beforeinput',e=>{
  const input=e.target;
  if(!v129IsZeroLike(input)||e.inputType!=='insertText'||!/^\d$/.test(e.data||''))return;
  e.preventDefault();
  input.value=e.data;
  input.dispatchEvent(new Event('input',{bubbles:true}));
});

function v129EnsurePlanTabs(){
  const panel=v129$('#financePlansTab');
  if(!panel||v129$('#v129PlanTabs'))return;
  const catalog=document.createElement('section');
  catalog.id='v129PlanCatalogTab';
  while(panel.firstChild)catalog.appendChild(panel.firstChild);

  const tabs=document.createElement('div');
  tabs.id='v129PlanTabs';
  tabs.className='client-subtabs';
  tabs.innerHTML=`
    <button class="active" data-v129-plan-mode="catalog" type="button">Planos</button>
    <button data-v129-plan-mode="contracts" type="button">Contratos ativos</button>
  `;

  const contracts=document.createElement('section');
  contracts.id='v129ContractsTab';
  contracts.className='hidden';
  contracts.innerHTML=`
    <div class="field client-search">
      <label>Buscar contrato</label>
      <input id="v129ContractSearch" placeholder="Cliente, plano ou WhatsApp">
    </div>
    <div id="v129ContractsList" class="finance-list"><div class="loading">Carregando contratos…</div></div>
  `;

  panel.append(tabs,catalog,contracts);
  v129$$('[data-v129-plan-mode]',tabs).forEach(btn=>btn.onclick=()=>v129SetPlanMode(btn.dataset.v129PlanMode));
  v129$('#v129ContractSearch').oninput=v129RenderContracts;
}
function v129SetPlanMode(mode){
  v129PlanMode=mode==='contracts'?'contracts':'catalog';
  v129$$('[data-v129-plan-mode]').forEach(b=>b.classList.toggle('active',b.dataset.v129PlanMode===v129PlanMode));
  v129$('#v129PlanCatalogTab')?.classList.toggle('hidden',v129PlanMode!=='catalog');
  v129$('#v129ContractsTab')?.classList.toggle('hidden',v129PlanMode!=='contracts');
  if(v129PlanMode==='contracts')v129LoadContracts();
}
async function v129LoadContracts(){
  const root=v129$('#v129ContractsList');
  if(!root)return;
  root.innerHTML='<div class="loading">Carregando contratos…</div>';
  try{
    v129Contracts=await v129Rpc('barberium_staff_membership_contracts');
    v129RenderContracts();
  }catch(err){
    root.innerHTML=`<div class="empty">${v129Esc(err?.message||'Não foi possível carregar os contratos.')}</div>`;
  }
}
function v129CreditSummary(m){
  return (m.credits||[]).map(c=>{
    if(c.unlimited)return `<span>${v129Esc(c.service)}: <b>Ilimitado</b></span>`;
    const label=m.plan_type==='subscription'?'uso(s)':'crédito(s)';
    return `<span>${v129Esc(c.service)}: <b>${Number(c.available)||0} ${label}</b></span>`;
  }).join('');
}
function v129RenderContracts(){
  const root=v129$('#v129ContractsList');
  if(!root)return;
  const q=(v129$('#v129ContractSearch')?.value||'').trim().toLocaleLowerCase('pt-BR');
  const rows=v129Contracts.filter(m=>!q||`${m.customer||''} ${m.name||''} ${m.phone||''}`.toLocaleLowerCase('pt-BR').includes(q));
  if(!rows.length){
    root.innerHTML=`<div class="empty">${q?'Nenhum contrato encontrado.':'Nenhum contrato ativo no momento.'}</div>`;
    return;
  }
  root.innerHTML=rows.map(m=>`
    <article class="plan-card">
      <div class="plan-head">
        <div>
          <span class="plan-tag">${m.plan_type==='subscription'?'ASSINATURA':'PACOTE'} • ${v129Esc(v129Status(m.status))}</span>
          <h3>${v129Esc(m.customer)}</h3>
          <p>${v129Esc(m.name)} • ${v129Money(m.price_cents)}${m.phone?` • ${v129Esc(m.phone)}`:''}</p>
        </div>
        <button class="soft-btn" data-v129-contract="${m.id}" type="button">Configurar</button>
      </div>
      <div class="credit-mini">${v129CreditSummary(m)}</div>
    </article>
  `).join('');
  v129$$('[data-v129-contract]').forEach(btn=>btn.onclick=()=>{
    const m=v129Contracts.find(x=>x.id===btn.dataset.v129Contract);
    if(m)v129OpenContract(m);
  });
}
function v129OpenContract(m){
  const pendingPay=m.plan_type==='package'
    ?m.status==='pending'
    :(m.cycles||[]).some(c=>['pending','overdue'].includes(c.status));
  const state=m.plan_type==='subscription'
    ?`${m.paused_until?`<div class="notice-box">Pausada até ${v129Date(m.paused_until)}.</div>`:''}${m.renewal_blocked?`<div class="notice-box">Cancelamento programado${m.cancel_effective_on?` para ${v129Date(m.cancel_effective_on)}`:''}.</div>`:''}`
    :'';
  v129OpenModal('CONTRATO',m.customer,`
    <div class="v129-contract-summary">
      <div class="detail-grid">
        <div class="detail-box"><small>Plano</small><strong>${v129Esc(m.name)}</strong></div>
        <div class="detail-box"><small>Status</small><strong>${v129Esc(v129Status(m.status))}</strong></div>
        <div class="detail-box"><small>Tipo</small><strong>${m.plan_type==='subscription'?'Assinatura':'Pacote'}</strong></div>
        <div class="detail-box"><small>Valor</small><strong>${v129Money(m.price_cents)}</strong></div>
        <div class="detail-box wide"><small>Cliente</small><strong>${v129Esc(m.customer)}${m.phone?` • ${v129Esc(m.phone)}`:''}</strong></div>
      </div>
      ${state}
      <h3 class="section-mini-title">${m.plan_type==='subscription'?'Benefícios':'Créditos'}</h3>
      <div class="credit-grid">
        ${(m.credits||[]).map(c=>`
          <div>
            <small>${v129Esc(c.service)}</small>
            <strong>${c.unlimited?'Ilimitado':`${Number(c.available)||0} disponível(is)`}</strong>
            <span>${Number(c.used)||0} usado(s) • ${Number(c.reserved)||0} reservado(s)${c.expires_on?` • vence ${v129Date(c.expires_on)}`:''}</span>
          </div>
        `).join('')||'<div><small>Benefícios</small><strong>Aguardando pagamento integral</strong></div>'}
      </div>
      <div class="v129-contract-actions">
        ${pendingPay?`<button class="gold-btn" data-v129-pay="${m.id}" type="button">Confirmar pagamento integral</button>`:''}
        ${m.plan_type==='package'&&m.status==='active'?`
          <button class="soft-btn" data-v129-adjust="${m.id}" type="button">Ajustar créditos</button>
          <button class="danger-btn" data-v129-cancel="${m.id}" type="button">Cancelar pacote</button>
        `:''}
      </div>
    </div>
  `);
  v129$('[data-v129-pay]')?.addEventListener('click',()=>v129OpenPayment(m));
  v129$('[data-v129-adjust]')?.addEventListener('click',()=>v129OpenCreditAdjustment(m));
  v129$('[data-v129-cancel]')?.addEventListener('click',()=>v129OpenCancellation(m));
}
function v129OpenCreditAdjustment(m){
  const finite=(m.credits||[]).filter(c=>!c.unlimited);
  if(!finite.length){v129Toast('Este pacote não possui créditos finitos para ajustar.');return}
  v129OpenModal('PACOTE',`Ajustar créditos • ${m.name}`,`
    <form id="v129CreditForm" class="form-grid">
      <div class="field"><label>Benefício</label><select id="v129CreditBucket">${finite.map(c=>`<option value="${c.bucket_id}">${v129Esc(c.service)} • ${Number(c.available)||0} disponíveis</option>`).join('')}</select></div>
      <div class="field"><label>Operação</label><select id="v129CreditOperation"><option value="add">Somar créditos</option><option value="subtract">Subtrair créditos</option></select></div>
      <div class="field"><label>Quantidade</label><input id="v129CreditQuantity" type="number" inputmode="numeric" min="1" step="1" placeholder="Ex.: 1" required></div>
      <div class="field"><label>Motivo obrigatório</label><textarea id="v129CreditReason" required></textarea></div>
      <button class="gold-btn" type="submit">Registrar ajuste</button>
    </form>
  `);
  v129$('#v129CreditForm').onsubmit=async e=>{
    e.preventDefault();
    const qty=Number(v129$('#v129CreditQuantity').value);
    if(!Number.isInteger(qty)||qty<=0){v129Toast('Informe uma quantidade inteira maior que zero.');return}
    const delta=v129$('#v129CreditOperation').value==='subtract'?-qty:qty;
    const reason=v129$('#v129CreditReason').value.trim();
    if(!reason){v129Toast('Informe o motivo do ajuste.');return}
    const btn=e.target.querySelector('[type=submit]');
    btn.disabled=true;
    try{
      await v129Rpc('barberium_staff_adjust_package_credit',{
        p_membership_id:m.id,
        p_bucket_id:v129$('#v129CreditBucket').value,
        p_delta:delta,
        p_reason:reason
      });
      v129Toast('Créditos ajustados e registrados no histórico.');
      v129CloseModal();
      await v129LoadContracts();
    }catch(err){
      v129Toast(err?.message||'Não foi possível ajustar os créditos.');
      btn.disabled=false;
    }
  };
}
function v129OpenPayment(m){
  const cycle=(m.cycles||[]).find(c=>['pending','overdue'].includes(c.status));
  v129OpenModal('PAGAMENTO INTEGRAL',m.name,`
    <div class="detail-grid">
      <div class="detail-box wide"><small>Valor integral</small><strong>${v129Money(cycle?.amount_cents||m.price_cents)}</strong></div>
      ${cycle?`<div class="detail-box"><small>Vencimento</small><strong>${v129Date(cycle.due_date)}</strong></div><div class="detail-box"><small>Status</small><strong>${v129Esc(v129Status(cycle.status))}</strong></div>`:''}
    </div>
    <div class="notice-box">O plano só será ativado após a confirmação deste pagamento integral.</div>
    <form id="v129PaymentForm" class="form-grid">
      <div class="field"><label>Forma de pagamento</label><select id="v129PaymentMethod"><option value="pix">Pix</option><option value="cash">Dinheiro</option><option value="debit">Débito</option><option value="credit">Crédito</option></select></div>
      <button class="gold-btn" type="submit">Confirmar pagamento integral</button>
    </form>
  `);
  v129$('#v129PaymentForm').onsubmit=async e=>{
    e.preventDefault();
    const btn=e.target.querySelector('[type=submit]');
    btn.disabled=true;
    try{
      await v129Rpc('barberium_staff_record_membership_payment',{
        p_membership_id:m.id,
        p_cycle_id:cycle?.id||null,
        p_method:v129$('#v129PaymentMethod').value
      });
      v129Toast(m.plan_type==='subscription'?'Pagamento confirmado. Benefícios liberados.':'Pagamento confirmado. Créditos liberados.');
      v129CloseModal();
      await v129LoadContracts();
    }catch(err){
      v129Toast(err?.message||'Não foi possível confirmar o pagamento.');
      btn.disabled=false;
    }
  };
}
function v129OpenCancellation(m){
  const policy=m.rules?.refund_mode||'nonrefundable';
  const labels={
    nonrefundable:'Sem reembolso',
    proportional:'Reembolso proporcional ao saldo não usado',
    manual:'Reembolso definido pelo ADM',
    no_after_use:'Cancelamento somente antes do primeiro uso'
  };
  v129OpenModal('CANCELAR PACOTE',m.name,`
    <div class="notice-box">Política deste pacote: <strong>${v129Esc(labels[policy]||policy)}</strong>.</div>
    <form id="v129CancelForm" class="form-grid">
      <div class="field"><label>Motivo obrigatório</label><textarea id="v129CancelReason" required></textarea></div>
      ${policy==='manual'?'<div class="field"><label>Valor do reembolso</label><input id="v129ManualRefund" inputmode="decimal" value="0,00"></div>':''}
      <button class="danger-btn" type="submit">Confirmar cancelamento</button>
    </form>
  `);
  v129$('#v129CancelForm').onsubmit=async e=>{
    e.preventDefault();
    if(!confirm('Confirmar o cancelamento deste pacote?'))return;
    const reason=v129$('#v129CancelReason').value.trim();
    if(!reason){v129Toast('Informe o motivo do cancelamento.');return}
    const btn=e.target.querySelector('[type=submit]');
    btn.disabled=true;
    try{
      const r=await v129Rpc('barberium_staff_cancel_package',{
        p_membership_id:m.id,
        p_reason:reason,
        p_manual_refund_cents:policy==='manual'?v129MoneyToCents(v129$('#v129ManualRefund').value):null
      });
      v129Toast(r?.refund_cents>0?`Pacote cancelado. Reembolso: ${v129Money(r.refund_cents)}`:'Pacote cancelado.');
      v129CloseModal();
      await v129LoadContracts();
    }catch(err){
      v129Toast(err?.message||'Não foi possível cancelar o pacote.');
      btn.disabled=false;
    }
  };
}

document.addEventListener('click',async e=>{
  const adjust=e.target.closest?.('[data-package-adjust]');
  if(adjust?.dataset?.packageAdjust){
    e.preventDefault();
    e.stopPropagation();
    e.stopImmediatePropagation();
    try{
      if(!v129Contracts.length)v129Contracts=await v129Rpc('barberium_staff_membership_contracts');
      const m=v129Contracts.find(x=>x.id===adjust.dataset.packageAdjust);
      if(!m)throw new Error('Contrato não encontrado.');
      v129OpenCreditAdjustment(m);
    }catch(err){v129Toast(err?.message||'Não foi possível abrir o ajuste de créditos.')}
    return;
  }

  const plans=e.target.closest?.('[data-finance-tab="plans"]');
  if(plans)setTimeout(()=>{v129EnsurePlanTabs();v129SetPlanMode(v129PlanMode)},0);
},true);

function v129Boot(){
  v129InjectFixStyle();
  v129EnsurePlanTabs();
  if(v129PlanMode==='contracts'&&!v129$('#financePlansTab')?.classList.contains('hidden'))v129LoadContracts();
}
if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',v129Boot);
else v129Boot();
setTimeout(v129Boot,400);
setTimeout(v129Boot,1200);
