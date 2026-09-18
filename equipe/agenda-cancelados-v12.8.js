const V128_SUPABASE_URL='https://pmvvawbaqylspxfmxezw.supabase.co';
const V128_SUPABASE_KEY='sb_publishable_CveglntZGjChE89lPcsQcg_EvBnYmKo';
const V128_AUTH_KEY='barberium_staff_auth_v1';

const v128$=(s,r=document)=>r.querySelector(s);
const v128$$=(s,r=document)=>[...r.querySelectorAll(s)];
const v128Esc=(v='')=>String(v).replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#039;'}[c]));
const v128Money=n=>new Intl.NumberFormat('pt-BR',{style:'currency',currency:'BRL'}).format((Number(n)||0)/100);

let v128LastAppointmentId=new URLSearchParams(location.search).get('appointment')||null;
let v128AgendaMode='agenda';
let v128ApplyingAgenda=false;

function v128GetAuth(){try{return JSON.parse(localStorage.getItem(V128_AUTH_KEY)||'null')}catch{return null}}
function v128SaveAuth(v){localStorage.setItem(V128_AUTH_KEY,JSON.stringify(v))}
async function v128AuthFetch(path,opts={}){
  const session=v128GetAuth();
  const headers={apikey:V128_SUPABASE_KEY,'Content-Type':'application/json',...(opts.headers||{})};
  if(session?.access_token)headers.Authorization=`Bearer ${session.access_token}`;
  let r=await fetch(`${V128_SUPABASE_URL}${path}`,{...opts,headers});
  if(r.status===401&&session?.refresh_token){
    const rr=await fetch(`${V128_SUPABASE_URL}/auth/v1/token?grant_type=refresh_token`,{
      method:'POST',
      headers:{apikey:V128_SUPABASE_KEY,'Content-Type':'application/json'},
      body:JSON.stringify({refresh_token:session.refresh_token})
    });
    if(rr.ok){
      const refreshed=await rr.json();
      v128SaveAuth(refreshed);
      headers.Authorization=`Bearer ${refreshed.access_token}`;
      r=await fetch(`${V128_SUPABASE_URL}${path}`,{...opts,headers});
    }
  }
  const text=await r.text();
  let data=null;try{data=text?JSON.parse(text):null}catch{data=text}
  if(!r.ok)throw new Error(data?.message||data?.msg||data?.error_description||data?.error||`Erro ${r.status}`);
  return data;
}
async function v128Rpc(name,payload={}){
  return v128AuthFetch(`/rest/v1/rpc/${name}`,{method:'POST',body:JSON.stringify(payload)});
}
function v128Toast(msg){
  const e=v128$('#toast');
  if(!e)return;
  e.textContent=msg;
  e.classList.add('show');
  clearTimeout(v128Toast.t);
  v128Toast.t=setTimeout(()=>e.classList.remove('show'),2800);
}
function v128OpenModal(eyebrow,title,html){
  const back=v128$('#modalBackdrop');
  if(!back)return;
  v128$('#modalEyebrow').textContent=eyebrow||'';
  v128$('#modalTitle').textContent=title||'';
  v128$('#modalBody').innerHTML=html;
  back.classList.remove('hidden');
  back.setAttribute('aria-hidden','false');
}
function v128CloseModal(){
  const back=v128$('#modalBackdrop');
  if(!back)return;
  back.classList.add('hidden');
  back.setAttribute('aria-hidden','true');
  v128$('#modalBody').innerHTML='';
}
function v128RefreshAgenda(){
  const dateInput=v128$('#dateInput');
  if(dateInput?.value){
    dateInput.dispatchEvent(new Event('change',{bubbles:true}));
  }
}

function v128InjectStyle(){
  if(v128$('#barberiumV128Style'))return;
  const style=document.createElement('style');
  style.id='barberiumV128Style';
  style.textContent=`
    #agendaStatusTabs{margin:14px 0 4px}
    #agendaStatusTabs button{min-width:120px}
    .v128-cancel-help{margin:-4px 0 8px;color:#98a79e;font-size:.83rem;line-height:1.45}
    .v128-booking-error-note{
      margin:0 0 12px;padding:12px 14px;border:1px solid rgba(214,174,91,.35);
      border-radius:14px;background:rgba(214,174,91,.08)
    }
    .v128-booking-error-note strong{display:block;margin-bottom:3px;color:#d6ae5b}
    .v128-booking-error-note p{margin:0;color:#b9c5bd;font-size:.86rem}
  `;
  document.head.appendChild(style);
}

function v128EnsureAgendaTabs(){
  const summary=v128$('#summary');
  const section=v128$('#agendaPanel .agenda-section');
  if(!summary||!section||v128$('#agendaStatusTabs'))return;
  const tabs=document.createElement('div');
  tabs.id='agendaStatusTabs';
  tabs.className='client-subtabs';
  tabs.innerHTML=`
    <button class="active" data-v128-agenda-mode="agenda" type="button">Agenda</button>
    <button data-v128-agenda-mode="cancelled" type="button">Cancelados</button>
  `;
  summary.insertAdjacentElement('afterend',tabs);
  v128$$('[data-v128-agenda-mode]',tabs).forEach(btn=>{
    btn.addEventListener('click',()=>{
      v128AgendaMode=btn.dataset.v128AgendaMode;
      v128$$('[data-v128-agenda-mode]',tabs).forEach(x=>x.classList.toggle('active',x===btn));
      v128ApplyAgendaMode();
    });
  });
  v128ApplyAgendaMode();
}

function v128ApplyAgendaMode(){
  if(v128ApplyingAgenda)return;
  const list=v128$('#agendaList');
  const section=v128$('#agendaPanel .agenda-section');
  if(!list||!section)return;
  v128ApplyingAgenda=true;
  try{
    const headSmall=section.querySelector('.section-head small');
    const headTitle=section.querySelector('.section-head h2');
    if(headSmall)headSmall.textContent=v128AgendaMode==='cancelled'?'CANCELADOS':'HORÁRIOS';
    if(headTitle)headTitle.textContent=v128AgendaMode==='cancelled'?'Cancelamentos do dia':'Agenda do dia';

    let generated=list.querySelector('#v128AgendaEmpty');

    const items=v128$$('.agenda-item',list);
    let visible=0;
    for(const item of items){
      const isCancelled=!!item.querySelector('.status.cancelled');
      const show=v128AgendaMode==='cancelled'?isCancelled:!isCancelled;
      item.hidden=!show;
      if(show)visible++;
    }

    const originalEmpty=list.querySelector('.empty:not(#v128AgendaEmpty)');
    if(originalEmpty&&items.length===0){
      originalEmpty.textContent=v128AgendaMode==='cancelled'
        ?'Nenhum cancelamento nesta data.'
        :'Nenhum horário ou bloqueio nesta data.';
    }else if(items.length>0&&visible===0&&!list.querySelector('.loading')){
      if(!generated){
        generated=document.createElement('div');
        generated.id='v128AgendaEmpty';
        generated.className='empty';
        list.appendChild(generated);
      }
      generated.textContent=v128AgendaMode==='cancelled'
        ?'Nenhum cancelamento nesta data.'
        :'Nenhum horário ou bloqueio nesta data.';
    }else if(generated){
      generated.remove();
    }
  }finally{
    v128ApplyingAgenda=false;
  }
}

function v128WireAgendaObserver(){
  const list=v128$('#agendaList');
  if(!list||list.dataset.v128Observed)return;
  list.dataset.v128Observed='1';
  new MutationObserver(()=>v128ApplyAgendaMode()).observe(list,{childList:true,subtree:true});
}

function v128CancelForm(kind='regular'){
  return `
    <form id="v128CancelForm" class="form-grid">
      <div class="field">
        <label>Tipo do cancelamento</label>
        <select id="v128CancelKind">
          <option value="regular" ${kind==='regular'?'selected':''}>Cancelamento normal</option>
          <option value="booking_error" ${kind==='booking_error'?'selected':''}>Engano / erro de agendamento</option>
        </select>
      </div>
      <p class="v128-cancel-help">
        Use “Engano / erro de agendamento” quando a comanda foi criada por engano, no barbeiro errado,
        horário errado ou em outra situação operacional semelhante.
      </p>
      <div class="field">
        <label>Observação (opcional)</label>
        <textarea id="v128CancelReason" placeholder="Ex.: marcado para o barbeiro errado"></textarea>
      </div>
      <button class="danger-btn finance-wide" type="submit">Confirmar cancelamento</button>
    </form>
  `;
}

function v128OpenRegularCancellation(id){
  v128OpenModal('CANCELAR ATENDIMENTO','Classificar cancelamento',v128CancelForm());
  const form=v128$('#v128CancelForm');
  form.onsubmit=async e=>{
    e.preventDefault();
    const btn=form.querySelector('[type=submit]');
    if(btn.disabled)return;
    const kind=v128$('#v128CancelKind').value;
    const typed=v128$('#v128CancelReason').value.trim();
    const reason=typed||(kind==='booking_error'?'Engano / erro de agendamento':'Cancelamento normal');
    btn.disabled=true;
    btn.textContent='Cancelando…';
    try{
      await v128Rpc('barberium_staff_cancel_appointment_v2',{
        p_appointment_id:id,
        p_cancellation_kind:kind,
        p_reason:reason
      });
      v128Toast(kind==='booking_error'?'Cancelado como engano/erro de agendamento.':'Atendimento cancelado.');
      v128CloseModal();
      v128RefreshAgenda();
    }catch(err){
      v128Toast(err?.message||'Não foi possível cancelar.');
      btn.disabled=false;
      btn.textContent='Confirmar cancelamento';
    }
  };
}

async function v128OpenCompletedCancellation(id){
  v128OpenModal('CANCELAR ATENDIMENTO CONCLUÍDO','Conferir devolução','<div class="loading">Conferindo pagamentos e produtos…</div>');
  try{
    const [d,f,p]=await Promise.all([
      v128Rpc('barberium_staff_appointment_detail',{p_appointment_id:id}),
      v128Rpc('barberium_staff_appointment_finance',{p_appointment_id:id}),
      v128Rpc('barberium_staff_appointment_products',{p_appointment_id:id})
    ]);
    const serviceRefund=Math.max(0,Number(f.paid_cents||0)-Number(f.refunds_cents||0));
    const productRefund=p.status==='completed'?Number(p.paid_cents||0):0;
    const pending=Number(f.receivable?.remaining_cents||0)+(p.status==='completed'?Number(p.pending_cents||0):0);

    v128OpenModal('CANCELAR ATENDIMENTO CONCLUÍDO',d.customer.name,`
      <form id="v128CancelCompletedForm" class="form-grid">
        <div class="detail-grid">
          <div class="detail-box"><small>Devolução do serviço</small><strong>${v128Money(serviceRefund)}</strong></div>
          <div class="detail-box"><small>Devolução dos produtos</small><strong>${v128Money(productRefund)}</strong></div>
          <div class="detail-box wide"><small>Total a devolver</small><strong>${v128Money(serviceRefund+productRefund)}</strong></div>
        </div>

        <div class="field">
          <label>Tipo do cancelamento</label>
          <select id="v128CompletedKind">
            <option value="regular">Cancelamento normal</option>
            <option value="booking_error">Engano / erro de agendamento</option>
          </select>
        </div>
        <p class="v128-cancel-help">
          “Engano / erro de agendamento” preserva o estorno e o histórico, mas não polui os relatórios
          como um cancelamento operacional normal.
        </p>

        <div class="detail-note">
          <p>O cancelamento reverte as comissões e devolve os produtos ao estoque.
          ${pending>0?` O saldo pendente de ${v128Money(pending)} será cancelado.`:''}
          ${(f.uses||[]).some(u=>u.status==='consumed')?' O benefício do plano/pacote será devolvido.':''}</p>
          <p>Os recebimentos e o estorno permanecem no histórico.</p>
        </div>

        <div class="field">
          <label>Forma da devolução</label>
          <select id="v128RefundMethod" required>
            <option value="">Selecione</option>
            <option value="pix">Pix</option>
            <option value="cash">Dinheiro</option>
            <option value="debit">Débito</option>
            <option value="credit">Crédito</option>
            <option value="transfer">Transferência</option>
            <option value="other">Outro / sem valor a devolver</option>
          </select>
        </div>

        <div class="field">
          <label>Motivo do cancelamento</label>
          <textarea id="v128CompletedReason" minlength="3" required></textarea>
        </div>

        <button class="danger-btn finance-wide" type="submit">Confirmar cancelamento e registrar estorno</button>
      </form>
    `);

    const form=v128$('#v128CancelCompletedForm');
    form.onsubmit=async e=>{
      e.preventDefault();
      const btn=form.querySelector('[type=submit]');
      if(btn.disabled)return;
      btn.disabled=true;
      try{
        const kind=v128$('#v128CompletedKind').value;
        await v128Rpc('barberium_staff_cancel_completed_appointment_v2',{
          p_appointment_id:id,
          p_reason:v128$('#v128CompletedReason').value.trim(),
          p_refund_method:v128$('#v128RefundMethod').value,
          p_cancellation_kind:kind
        });
        v128Toast(kind==='booking_error'
          ?'Cancelado como engano/erro. Estornos e histórico preservados.'
          :'Atendimento cancelado. Estorno, estoque e comissões atualizados.');
        v128CloseModal();
        v128RefreshAgenda();
      }catch(err){
        v128Toast(err?.message||'Não foi possível cancelar.');
        btn.disabled=false;
      }
    };
  }catch(err){
    const body=v128$('#modalBody');
    if(body)body.innerHTML=`<div class="empty">${v128Esc(err?.message||'Não foi possível conferir o atendimento.')}</div>`;
  }
}

async function v128DecorateCancelledDetail(id){
  setTimeout(async()=>{
    const modal=v128$('#modalBackdrop');
    const body=v128$('#modalBody');
    if(!modal||modal.classList.contains('hidden')||!body||body.dataset.v128CancellationDecorated===id)return;
    try{
      const d=await v128Rpc('barberium_staff_appointment_detail',{p_appointment_id:id});
      if(d?.status!=='cancelled')return;
      const event=(d.events||[]).slice().reverse().find(e=>
        e?.details?.cancellation_kind==='booking_error'
      );
      if(!event)return;
      body.dataset.v128CancellationDecorated=id;
      const note=document.createElement('div');
      note.className='v128-booking-error-note';
      note.innerHTML='<strong>Engano / erro de agendamento</strong><p>Este cancelamento foi classificado como correção operacional.</p>';
      body.prepend(note);
    }catch{}
  },350);
}

function v128CleanCommissionSummary(){
  const root=v128$('#commissionContent');
  if(!root)return;
  for(const card of v128$$('.service-stat',root)){
    const h=card.querySelector('h3');
    if(!h)continue;
    const m=h.textContent.match(/Cancelamentos?\s+por\s+erro\s+de\s+agendamento:\s*(\d+)/i);
    if(!m)continue;
    h.textContent=`Cancelamento por erro de agendamento: ${m[1]}`;
    const p=card.querySelector('p');
    if(p)p.style.display='none';
    const strong=card.querySelector(':scope > strong');
    if(strong)strong.style.display='none';
  }
}

function v128WireCommissionObserver(){
  const root=v128$('#commissionContent');
  if(!root||root.dataset.v128Observed)return;
  root.dataset.v128Observed='1';
  new MutationObserver(()=>v128CleanCommissionSummary()).observe(root,{childList:true,subtree:true});
  v128CleanCommissionSummary();
}

document.addEventListener('click',e=>{
  const appt=e.target.closest?.('[data-appt-id]');
  if(appt?.dataset?.apptId){
    v128LastAppointmentId=appt.dataset.apptId;
    v128DecorateCancelledDetail(v128LastAppointmentId);
  }

  const simpleCancel=e.target.closest?.('[data-new-status="cancelled"]');
  if(simpleCancel&&v128LastAppointmentId){
    e.preventDefault();
    e.stopPropagation();
    e.stopImmediatePropagation();
    v128OpenRegularCancellation(v128LastAppointmentId);
    return;
  }

  const completedCancel=e.target.closest?.('#cancelCompletedAppointment');
  if(completedCancel&&v128LastAppointmentId){
    e.preventDefault();
    e.stopPropagation();
    e.stopImmediatePropagation();
    v128OpenCompletedCancellation(v128LastAppointmentId);
  }
},true);

function v128Boot(){
  v128InjectStyle();
  v128EnsureAgendaTabs();
  v128WireAgendaObserver();
  v128WireCommissionObserver();
  v128ApplyAgendaMode();
}

if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',v128Boot);
else v128Boot();

setTimeout(v128Boot,400);
setTimeout(v128Boot,1200);
