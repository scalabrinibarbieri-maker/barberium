const SUPABASE_URL='https://pmvvawbaqylspxfmxezw.supabase.co';
const SUPABASE_KEY='sb_publishable_CveglntZGjChE89lPcsQcg_EvBnYmKo';
const AUTH_KEY='barberium_staff_auth_v1';
const TZ='America/Sao_Paulo';

const $=s=>document.querySelector(s);
const $$=(s,r=document)=>[...r.querySelectorAll(s)];
const moneyCents=n=>new Intl.NumberFormat('pt-BR',{style:'currency',currency:'BRL'}).format((Number(n)||0)/100);
const pad=n=>String(n).padStart(2,'0');
const isoDate=d=>`${d.getFullYear()}-${pad(d.getMonth()+1)}-${pad(d.getDate())}`;
const esc=(v='')=>String(v).replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#039;'}[c]));

let member=null;
let catalog={professionals:[],services:[],permissions:{}};
let currentDate=isoDate(new Date());
let filterProfessionalId=null;
let activePeriod='today';
let currentAgenda=null;
let currentPanel='agenda';

function getAuth(){try{return JSON.parse(localStorage.getItem(AUTH_KEY)||'null')}catch{return null}}
function saveAuth(v){localStorage.setItem(AUTH_KEY,JSON.stringify(v))}
function clearAuth(){localStorage.removeItem(AUTH_KEY)}
function isManager(){return ['owner','admin'].includes(member?.role)}
function can(key){return isManager()||member?.permissions?.[key]===true}
function toast(msg){const e=$('#toast');e.textContent=msg;e.classList.add('show');clearTimeout(toast.t);toast.t=setTimeout(()=>e.classList.remove('show'),2600)}
function friendlyError(e){const m=String(e?.message||e);if(/Horário ocupado|already|exclusion/i.test(m))return'Esse horário já está ocupado.';if(/bloquead/i.test(m))return'Esse período está bloqueado.';return m}

async function authFetch(path,opts={}){
  const session=getAuth();
  const headers={apikey:SUPABASE_KEY,'Content-Type':'application/json',...(opts.headers||{})};
  if(session?.access_token)headers.Authorization=`Bearer ${session.access_token}`;
  let r=await fetch(`${SUPABASE_URL}${path}`,{...opts,headers});
  if(r.status===401&&session?.refresh_token){
    const rr=await fetch(`${SUPABASE_URL}/auth/v1/token?grant_type=refresh_token`,{method:'POST',headers:{apikey:SUPABASE_KEY,'Content-Type':'application/json'},body:JSON.stringify({refresh_token:session.refresh_token})});
    if(rr.ok){const refreshed=await rr.json();saveAuth(refreshed);headers.Authorization=`Bearer ${refreshed.access_token}`;r=await fetch(`${SUPABASE_URL}${path}`,{...opts,headers})}
  }
  const text=await r.text();let data=null;try{data=text?JSON.parse(text):null}catch{data=text}
  if(!r.ok)throw new Error(data?.message||data?.msg||data?.error_description||data?.error||`Erro ${r.status}`);
  return data;
}
async function rpc(name,payload={}){return authFetch(`/rest/v1/rpc/${name}`,{method:'POST',body:JSON.stringify(payload)})}

async function login(email,password){
  const r=await fetch(`${SUPABASE_URL}/auth/v1/token?grant_type=password`,{method:'POST',headers:{apikey:SUPABASE_KEY,'Content-Type':'application/json'},body:JSON.stringify({email,password})});
  const data=await r.json().catch(()=>({}));if(!r.ok)throw new Error(data?.error_description||data?.msg||'E-mail ou senha inválidos.');saveAuth(data);
  try{member=await rpc('barberium_staff_me');return member}catch{clearAuth();throw new Error('Este login não possui acesso à Área da Equipe.')}
}
async function logout(){try{await authFetch('/auth/v1/logout',{method:'POST',body:'{}'})}catch{}clearAuth();member=null;showLogin()}
function showLogin(){$('#loginView').classList.remove('hidden');$('#dashboardView').classList.add('hidden');$('#password').value=''}

function roleName(){return member?.role==='owner'?'Proprietário':member?.role==='admin'?'Administrador':'Barbeiro'}
function partsSP(ts){const p=Object.fromEntries(new Intl.DateTimeFormat('en-CA',{timeZone:TZ,year:'numeric',month:'2-digit',day:'2-digit',hour:'2-digit',minute:'2-digit',hourCycle:'h23'}).formatToParts(new Date(ts)).filter(x=>x.type!=='literal').map(x=>[x.type,x.value]));return{date:`${p.year}-${p.month}-${p.day}`,time:`${p.hour}:${p.minute}`}}
function timeBR(ts){return new Intl.DateTimeFormat('pt-BR',{timeZone:TZ,hour:'2-digit',minute:'2-digit',hour12:false}).format(new Date(ts))}
function dateLong(iso){return new Intl.DateTimeFormat('pt-BR',{weekday:'short',day:'2-digit',month:'short'}).format(new Date(`${iso}T12:00:00`)).replace(/\./g,'')}
function dateShort(iso){return new Intl.DateTimeFormat('pt-BR',{day:'2-digit',month:'short'}).format(new Date(`${iso}T12:00:00`)).replace(/\./g,'')}
function dateTimeBR(ts){return new Intl.DateTimeFormat('pt-BR',{timeZone:TZ,day:'2-digit',month:'2-digit',year:'numeric',hour:'2-digit',minute:'2-digit'}).format(new Date(ts))}
function statusLabel(v){return({confirmed:'Confirmado',completed:'Concluído',cancelled:'Cancelado',no_show:'Não compareceu'})[v]||v}
function serviceById(id){return catalog.services.find(s=>s.id===id)}
function professionalById(id){return catalog.professionals.find(p=>p.id===id)}

async function showDashboard(){
  $('#loginView').classList.add('hidden');$('#dashboardView').classList.remove('hidden');
  catalog=await rpc('barberium_staff_catalog');member.permissions=catalog.permissions||member.permissions||{};
  $('#roleLabel').textContent=roleName();$('#performanceRole').textContent=roleName();
  $('#welcomeName').textContent=member?.professional_name?`Olá, ${member.professional_name.split(' ')[0]}.`:'Painel da unidade';
  $('#scopeLabel').textContent=isManager()?'Você está vendo a agenda de toda a equipe.':'Você está vendo apenas a sua própria agenda.';
  $('#performanceTitle').textContent=isManager()?'Desempenho da unidade':'Seu desempenho';
  $('#performanceScope').textContent=isManager()?'Resumo financeiro e operacional da equipe.':'Somente seus atendimentos entram nestes números.';
  $('#professionalFilterWrap').classList.toggle('hidden',!isManager());
  $('#teamNav').classList.toggle('hidden',!isManager());
  $('#clientsNav').classList.toggle('hidden',!isManager());
  $('#financeNav').classList.toggle('hidden',!(isManager()||can('view_own_commission')));
  $('#performanceNav').classList.toggle('hidden',!can('view_own_revenue'));
  $('#newAppointmentButton').classList.toggle('hidden',!can('create_appointment'));
  $('#newBlockButton').classList.toggle('hidden',!(can('create_block')||can('create_recurring_block')));
  const visibleNav=$$('#teamBottomNav button:not(.hidden)').length;
  ['five','four','two','one'].forEach(c=>$('#teamBottomNav').classList.remove(c));
  if(visibleNav===5)$('#teamBottomNav').classList.add('five');if(visibleNav===4)$('#teamBottomNav').classList.add('four');if(visibleNav===2)$('#teamBottomNav').classList.add('two');if(visibleNav===1)$('#teamBottomNav').classList.add('one');
  filterProfessionalId=null;renderProfessionalFilter();renderDate();await loadAgenda();
}
function renderProfessionalFilter(){if(!isManager())return;$('#professionalFilter').innerHTML=[`<button class="chip ${filterProfessionalId===null?'active':''}" data-filter-prof="">Todos</button>`,...catalog.professionals.map(p=>`<button class="chip ${filterProfessionalId===p.id?'active':''}" data-filter-prof="${p.id}">${esc(p.name.split(' ')[0])}</button>`)].join('');$$('[data-filter-prof]').forEach(b=>b.onclick=()=>{filterProfessionalId=b.dataset.filterProf||null;renderProfessionalFilter();loadAgenda()})}
function renderDate(){$('#dateLabel').textContent=dateLong(currentDate);$('#dateInput').value=currentDate}
function moveDate(days){const d=new Date(`${currentDate}T12:00:00`);d.setDate(d.getDate()+days);currentDate=isoDate(d);renderDate();loadAgenda()}

async function loadAgenda(){
  $('#agendaList').innerHTML='<div class="loading">Carregando agenda…</div>';
  try{currentAgenda=await rpc('barberium_staff_dashboard',{p_date:currentDate,p_professional_id:isManager()?filterProfessionalId:null});renderSummary(currentAgenda.summary||{});renderAgenda(currentAgenda)}catch(e){if(/JWT|token|autenticado/i.test(e.message)){clearAuth();showLogin();return}$('#agendaList').innerHTML=`<div class="empty">${esc(friendlyError(e))}</div>`}
}
function renderSummary(s){
  const ownRevenue=can('view_own_revenue');
  const cards=isManager()?[
    ['Horários',s.total||0,''],['Confirmados',s.confirmed||0,''],['Previsto',moneyCents(s.revenue_cents||0),'gold']
  ]:ownRevenue?[
    ['Horários',s.total||0,''],['Realizado',moneyCents(s.realized_revenue_cents||0),'gold'],['Agendado',moneyCents(s.scheduled_revenue_cents||0),'']
  ]:[['Horários',s.total||0,''],['Confirmados',s.confirmed||0,''],['Concluídos',s.completed||0,'']];
  $('#summary').innerHTML=cards.map(([l,v,c])=>`<article class="summary-card ${c}"><small>${l}</small><strong>${v}</strong></article>`).join('');
}
function renderAgenda(data){
  const items=[...(data.appointments||[]),...(data.blocks||[])].sort((a,b)=>new Date(a.starts_at)-new Date(b.starts_at));
  if(!items.length){$('#agendaList').innerHTML='<div class="empty">Nenhum horário ou bloqueio nesta data.</div>';return}
  $('#agendaList').innerHTML=items.map(x=>x.kind==='block'?blockCard(x):appointmentCard(x)).join('');
  $$('[data-appt-id]').forEach(b=>b.onclick=()=>openAppointmentDetail(b.dataset.apptId));
  $$('[data-block-id]').forEach(b=>b.onclick=()=>openBlockDetail(b.dataset.blockId,b.dataset.blockKind));
}
function appointmentCard(a){const addons=(a.addons||[]).map(x=>x.name).join(' + ');return `<button class="agenda-item" data-appt-id="${a.id}" type="button"><div class="agenda-time"><strong>${timeBR(a.starts_at)}</strong><small>${timeBR(a.ends_at)}</small></div><div class="agenda-body"><div class="agenda-top"><h3>${esc(a.customer)}</h3><span class="status ${a.status}">${statusLabel(a.status)}</span></div><p class="agenda-service">${esc(a.service)}${addons?` + ${esc(addons)}`:''}</p><div class="agenda-meta">${isManager()?`<span>${esc(a.professional)}</span>`:''}${a.total_price_cents!==null?`<span>${moneyCents(a.total_price_cents)}</span>`:''}${a.internal_note?'<span class="note-flag">Nota interna</span>':''}</div></div></button>`}
function blockCard(b){return `<button class="agenda-item block" data-block-id="${b.id}" data-block-kind="${b.block_type}" type="button"><div class="agenda-time"><strong>${timeBR(b.starts_at)}</strong><small>${timeBR(b.ends_at)}</small></div><div class="agenda-body"><div class="agenda-top"><h3>Bloqueado</h3><span class="status blocked">${b.recurring?'Recorrente':'Bloqueio'}</span></div><p class="agenda-service">${esc(b.reason||'Sem motivo informado')}</p><div class="agenda-meta">${isManager()?`<span>${esc(b.professional)}</span>`:''}</div></div></button>`}

function openModal(eyebrow,title,html){$('#modalEyebrow').textContent=eyebrow||'';$('#modalTitle').textContent=title||'';$('#modalBody').innerHTML=html;$('#modalBackdrop').classList.remove('hidden');$('#modalBackdrop').setAttribute('aria-hidden','false')}
function closeModal(){$('#modalBackdrop').classList.add('hidden');$('#modalBackdrop').setAttribute('aria-hidden','true');$('#modalBody').innerHTML=''}

async function openAppointmentDetail(id){
  openModal('ATENDIMENTO','Carregando…','<div class="loading">Buscando detalhes…</div>');
  try{const d=await rpc('barberium_staff_appointment_detail',{p_appointment_id:id});renderAppointmentDetail(d)}catch(e){$('#modalBody').innerHTML=`<div class="empty">${esc(friendlyError(e))}</div>`}
}
function renderAppointmentDetail(d){
  $('#modalTitle').textContent=d.customer.name;
  const pt=partsSP(d.starts_at);const addons=(d.addons||[]).map(a=>a.name).join(' + ');
  const valueHtml=d.total_price_cents!==null?`<div class="detail-box"><small>Valor original</small><strong>${moneyCents(d.listed_price_cents)}</strong></div><div class="detail-box"><small>Ajuste</small><strong>${d.manual_adjustment_cents>0?'+ ':''}${moneyCents(d.manual_adjustment_cents)}</strong></div><div class="detail-box wide"><small>Valor final</small><strong>${moneyCents(d.total_price_cents)}</strong></div>`:'';
  const stats=d.customer_stats?`<h3 class="section-mini-title">Cliente</h3><div class="detail-grid"><div class="detail-box"><small>Atendimentos</small><strong>${d.customer_stats.appointments}</strong></div><div class="detail-box"><small>Concluídos</small><strong>${d.customer_stats.completed}</strong></div>${d.total_price_cents!==null?`<div class="detail-box wide"><small>Total já atendido</small><strong>${moneyCents(d.customer_stats.spent_cents)}</strong></div>`:''}</div>`:'';
  const history=isManager()&&d.events?.length?`<h3 class="section-mini-title">Histórico de alterações</h3><div class="history-list">${d.events.map(eventHtml).join('')}</div>`:'';
  const canEdit=isManager()||['edit_service','edit_addons','edit_date','edit_time','edit_value','edit_internal_note'].some(can);
  const statusBtns=statusButtons(d);
  $('#modalBody').innerHTML=`
    <div class="detail-grid">
      <div class="detail-box"><small>Status</small><strong>${statusLabel(d.status)}</strong></div>
      <div class="detail-box"><small>Profissional</small><strong>${esc(d.professional.name)}</strong></div>
      <div class="detail-box"><small>Data</small><strong>${dateShort(pt.date)}</strong></div>
      <div class="detail-box"><small>Horário</small><strong>${pt.time}–${timeBR(d.ends_at)}</strong></div>
      <div class="detail-box wide"><small>Serviço</small><strong>${esc(d.service.name)}${addons?` + ${esc(addons)}`:''}</strong></div>
      ${d.customer.phone?`<div class="detail-box wide"><small>WhatsApp</small><strong>${esc(d.customer.phone)}</strong></div>`:''}
      ${d.customer.birthday?`<div class="detail-box wide"><small>Aniversário</small><strong>${esc(d.customer.birthday)}</strong></div>`:''}
      ${valueHtml}
    </div>
    ${d.internal_note?`<div class="detail-note"><small>OBSERVAÇÃO INTERNA</small><p>${esc(d.internal_note)}</p></div>`:''}
    ${stats}
    <div class="action-row">
      ${d.customer.phone?`<a class="soft-btn" href="https://wa.me/${String(d.customer.phone).replace(/\D/g,'')}" target="_blank" rel="noopener">Abrir WhatsApp</a>`:''}
      ${canEdit?'<button id="editAppointment" class="soft-btn" type="button">Editar atendimento</button>':''}
      ${isManager()&&d.status==='confirmed'?'<button id="applyMembershipUse" class="soft-btn" type="button">Usar assinatura/pacote</button>':''}
    </div>
    ${statusBtns?`<h3 class="section-mini-title">Alterar status</h3><div class="action-row" id="statusActions">${statusBtns}</div>`:''}
    ${history}`;
  $('#editAppointment')?.addEventListener('click',()=>openBookingModal('edit',d));
  $('#applyMembershipUse')?.addEventListener('click',()=>openMembershipUseModal(d.id));
  $$('[data-new-status]').forEach(b=>b.onclick=()=>changeStatus(d.id,b.dataset.newStatus));
  if(d.status==='completed')injectAppointmentFinanceSummary(d.id);if(d.status==='no_show'&&isManager())injectNoShowMembershipDecision(d.id);
}
async function injectAppointmentFinanceSummary(id){try{const f=await rpc('barberium_staff_appointment_finance',{p_appointment_id:id});const actions=$('#statusActions')?.parentElement||$('#modalBody');if(!actions||$('#appointmentFinanceSummary'))return;const rec=f.receivable;const html=`<section id="appointmentFinanceSummary"><h3 class="section-mini-title">Financeiro</h3><div class="detail-grid"><div class="detail-box"><small>Recebido</small><strong>${moneyCents(f.paid_cents)}</strong></div><div class="detail-box"><small>Taxas</small><strong>${moneyCents(f.fees_cents)}</strong></div><div class="detail-box"><small>Plano/pacote</small><strong>${moneyCents(f.membership_covered_cents)}</strong></div>${rec?`<div class="detail-box"><small>Pendente</small><strong>${moneyCents(rec.remaining_cents)}</strong></div>`:''}</div></section>`;actions.insertAdjacentHTML('beforeend',html)}catch(e){console.error(e)}}
async function injectNoShowMembershipDecision(id){
  try{const f=await rpc('barberium_staff_appointment_finance',{p_appointment_id:id});const pending=(f.uses||[]).filter(u=>u.status==='decision_required');if(!pending.length||$('#noShowMembershipDecision'))return;const root=$('#modalBody');root.insertAdjacentHTML('beforeend',`<section id="noShowMembershipDecision"><h3 class="section-mini-title">Falta • benefício do plano</h3><div class="notice-box">Este plano está configurado para o ADM decidir se a falta conta como uso.</div>${pending.map(u=>`<article class="service-stat"><div><h3>${esc(u.plan)} • ${esc(u.service)}</h3><p>Decisão pendente</p></div><div class="action-row"><button class="danger-btn small" data-no-show-consume="${u.id}" type="button">Contar como uso</button><button class="soft-btn small" data-no-show-keep="${u.id}" type="button">Manter benefício</button></div></article>`).join('')}</section>`);$$('[data-no-show-consume]').forEach(b=>b.onclick=()=>resolveNoShowMembershipUse(id,b.dataset.noShowConsume,true));$$('[data-no-show-keep]').forEach(b=>b.onclick=()=>resolveNoShowMembershipUse(id,b.dataset.noShowKeep,false))}catch(e){console.error(e)}
}
async function resolveNoShowMembershipUse(appointmentId,useId,consume){try{await rpc('barberium_staff_resolve_no_show_membership_use',{p_use_id:useId,p_consume:consume,p_note:null});toast(consume?'Falta registrada como uso.':'Benefício mantido para o cliente.');openAppointmentDetail(appointmentId)}catch(e){toast(friendlyError(e))}}
async function openMembershipUseModal(appointmentId){openModal('PLANO / PACOTE','Aplicar benefício','<div class="loading">Buscando benefícios disponíveis…</div>');try{const [opts,fin]=await Promise.all([rpc('barberium_staff_membership_options_for_appointment',{p_appointment_id:appointmentId}),rpc('barberium_staff_appointment_finance',{p_appointment_id:appointmentId})]);const existing=fin.uses||[];$('#modalBody').innerHTML=`${existing.length?`<h3 class="section-mini-title">Já reservado</h3>${existing.map(u=>`<article class="service-stat"><div><h3>${esc(u.plan)} • ${esc(u.service)}</h3><p>${financeStatusLabel(u.status)}</p></div><strong>${moneyCents(u.coverage_cents)}</strong></article>`).join('')}`:''}<h3 class="section-mini-title">Disponíveis</h3>${opts.length?opts.map((o,i)=>`<button class="client-card" data-use-option="${i}" type="button"><h3>${esc(o.plan)} • ${esc(o.covered_service)}</h3><p>Aplicar em ${esc(o.target_service)} • ${o.unlimited?'Ilimitado':`${o.available} uso${o.available===1?'':'s'} disponível${o.available===1?'':'is'}`}${o.expires_on?` • vence ${brDateOnly(o.expires_on)}`:''}</p><div class="client-meta"><span>Abatimento ${moneyCents(o.coverage_cents)}</span></div></button>`).join(''):'<div class="empty">Nenhum benefício disponível para este atendimento.</div>'}`;$$('[data-use-option]').forEach(b=>b.onclick=async()=>{const o=opts[Number(b.dataset.useOption)];b.disabled=true;try{await rpc('barberium_staff_reserve_membership_use',{p_appointment_id:appointmentId,p_membership_id:o.membership_id,p_benefit_id:o.benefit_id,p_bucket_id:o.bucket_id,p_target_service_id:o.target_service_id});toast('Benefício reservado para este atendimento.');await openMembershipUseModal(appointmentId)}catch(e){toast(friendlyError(e));b.disabled=false}})}catch(e){$('#modalBody').innerHTML=`<div class="empty">${esc(friendlyError(e))}</div>`}}
function statusButtons(d){
  const options=[];
  if(d.status==='confirmed'){
    if(isManager()||can('mark_completed'))options.push('completed');
    if(isManager()||can('mark_no_show'))options.push('no_show');
    if(isManager()||can('cancel_appointment'))options.push('cancelled');
  }else if(isManager()&&['cancelled','no_show'].includes(d.status))options.push('confirmed');
  return options.map(s=>`<button class="${s==='cancelled'?'danger-btn':'soft-btn'}" data-new-status="${s}" type="button">${statusLabel(s)}</button>`).join('');
}
async function changeStatus(id,status){
  if(status==='completed'){openCompleteAppointment(id);return}
  if(!confirm(`Alterar este atendimento para “${statusLabel(status)}”?`))return;
  try{await rpc('barberium_staff_set_appointment_status',{p_appointment_id:id,p_status:status});toast('Status atualizado.');await loadAgenda();await openAppointmentDetail(id)}catch(e){toast(friendlyError(e))}
}
function eventHtml(e){
  let title='Alteração no atendimento',desc='';
  if(e.event_type==='created'){title='Agendamento criado';desc=`Criado por ${e.actor}.`}
  if(e.event_type==='status_changed'){title='Status alterado';desc=`${statusLabel(e.details?.from)} → ${statusLabel(e.details?.to)} • ${e.actor}`}
  if(e.event_type==='edited'){
    const c=[];if(e.details?.professional_changed)c.push('profissional');if(e.details?.service_changed)c.push('serviço');if(e.details?.addons_changed)c.push('adicionais');if(e.details?.date_changed)c.push('data');if(e.details?.time_changed)c.push('horário');if(e.details?.value_changed)c.push('valor');if(e.details?.note_changed)c.push('observação');
    title='Atendimento editado';desc=`${c.length?`Alterado: ${c.join(', ')}.`:'Dados atualizados.'} • ${e.actor}`;
  }
  return `<div class="history-item"><strong>${esc(title)}</strong><p>${esc(desc)}</p><time>${dateTimeBR(e.created_at)}</time></div>`
}

async function openBookingModal(mode,detail=null){
  const edit=mode==='edit';
  const pt=edit?partsSP(detail.starts_at):{date:currentDate,time:''};
  const selectedCustomer={id:edit?detail.customer.id:null,name:edit?detail.customer.name:'',phone:edit?detail.customer.phone:''};
  const professionalId=edit?detail.professional.id:(isManager()?(filterProfessionalId||catalog.professionals[0]?.id):member.professional_id);
  const serviceId=edit?detail.service.id:catalog.services[0]?.id;
  const addonIds=edit?(detail.addons||[]).map(a=>a.service_id):[];
  const canValue=isManager()||can('edit_value')||can('view_value');
  const canNote=isManager()||can('edit_internal_note')||can('view_internal_note');
  const price=edit&&detail.total_price_cents!==null?detail.total_price_cents:calcListed(serviceId,addonIds);
  openModal(edit?'EDITAR ATENDIMENTO':'NOVO HORÁRIO',edit?detail.customer.name:'Agendamento manual',bookingFormHtml({edit,selectedCustomer,professionalId,serviceId,addonIds,date:pt.date,time:pt.time,price,note:edit?(detail.internal_note||''):''},canValue,canNote));
  const state={edit,detail,customer:selectedCustomer,newCustomer:false,professionalId,serviceId,addonIds:[...addonIds],date:pt.date,time:pt.time,manualPriceCents:price};
  bindBookingForm(state);await refreshBookingDynamic(state,true);
}
function bookingFormHtml(st,showValue,showNote){
  const proOptions=catalog.professionals.map(p=>`<option value="${p.id}" ${p.id===st.professionalId?'selected':''}>${esc(p.name)}</option>`).join('');
  const serviceOptions=catalog.services.map(s=>`<option value="${s.id}" ${s.id===st.serviceId?'selected':''}>${esc(s.name)}</option>`).join('');
  return `<form id="bookingForm" class="form-grid">
    <section class="form-section" id="customerSection">
      <h3>Cliente</h3>
      ${st.edit?`<div class="selected-customer"><strong>${esc(st.selectedCustomer.name)}</strong><small>${st.selectedCustomer.phone?esc(st.selectedCustomer.phone):'Cliente do atendimento'}</small></div>`:`
      <div class="field"><label>Buscar cliente</label><input id="customerSearch" placeholder="Nome ou telefone"></div>
      <div class="action-row"><button id="searchCustomerButton" class="soft-btn" type="button">Buscar</button><button id="newCustomerButton" class="soft-btn" type="button">+ Novo cliente</button></div>
      <div id="customerResults" class="customer-results"></div>
      <div id="selectedCustomerWrap"></div>
      <div id="newCustomerFields" class="form-grid hidden"><div class="field"><label>Nome e sobrenome</label><input id="newCustomerName"></div><div class="field"><label>WhatsApp</label><input id="newCustomerPhone" inputmode="tel" placeholder="(11) 99999-9999"></div></div>`}
    </section>
    <section class="form-section"><h3>Atendimento</h3>
      <div class="field"><label>Profissional</label><select id="bookingProfessional" ${isManager()?'':'disabled'}>${proOptions}</select></div>
      <div class="field"><label>Serviço</label><select id="bookingService" ${st.edit&&!isManager()&&!can('edit_service')?'disabled':''}>${serviceOptions}</select></div>
      <div><label class="field">Adicionais</label><div id="addonOptions" class="addon-options"></div></div>
    </section>
    <section class="form-section"><h3>Data e horário</h3><div class="form-grid two"><div class="field"><label>Data</label><input id="bookingDate" type="date" value="${st.date}" ${st.edit&&!isManager()&&!can('edit_date')?'disabled':''}></div><div class="field"><label>Horário</label><select id="bookingTime" ${st.edit&&!isManager()&&!can('edit_time')?'disabled':''}><option value="">Carregando…</option></select></div></div></section>
    ${showValue?`<section class="form-section"><h3>Valor</h3><div class="price-preview"><span>Preço de tabela</span><strong id="listedPrice">${moneyCents(calcListed(st.serviceId,st.addonIds))}</strong></div><div class="field"><label>Valor final</label><input id="finalPrice" type="number" min="0" step="0.01" value="${(st.price/100).toFixed(2)}" ${isManager()||can('edit_value')?'':'disabled'}></div></section>`:''}
    ${showNote?`<section class="form-section"><h3>Observação interna</h3><div class="field"><textarea id="internalNote" placeholder="Visível somente para a equipe" ${isManager()||can('edit_internal_note')?'':'readonly'}>${esc(st.note)}</textarea></div></section>`:''}
    <button id="saveBooking" class="gold-btn" type="submit">${st.edit?'Salvar alterações':'Criar agendamento'}</button>
  </form>`
}
function calcListed(serviceId,addonIds){const s=serviceById(serviceId);return(s?.price_cents||0)+(s?.addons||[]).filter(a=>addonIds.includes(a.service_id)).reduce((sum,a)=>sum+(a.price_cents||0),0)}
function bindBookingForm(st){
  if(!st.edit){
    $('#searchCustomerButton').onclick=()=>searchCustomers(st);$('#customerSearch').addEventListener('keydown',e=>{if(e.key==='Enter'){e.preventDefault();searchCustomers(st)}});
    $('#newCustomerButton').onclick=()=>{st.newCustomer=true;st.customer={id:null,name:'',phone:''};$('#newCustomerFields').classList.remove('hidden');$('#selectedCustomerWrap').innerHTML='';$('#customerResults').innerHTML=''};
  }
  $('#bookingProfessional').onchange=e=>{st.professionalId=e.target.value;refreshSlots(st)};
  $('#bookingService').onchange=e=>{st.serviceId=e.target.value;st.addonIds=[];renderAddonOptions(st);syncPrice(st,true);refreshSlots(st)};
  $('#bookingDate').onchange=e=>{st.date=e.target.value;refreshSlots(st)};
  $('#finalPrice')?.addEventListener('input',e=>{st.manualPriceCents=Math.round((Number(e.target.value)||0)*100)});
  $('#bookingForm').onsubmit=e=>saveBooking(e,st);
}
async function searchCustomers(st){
  const q=$('#customerSearch').value.trim();$('#customerResults').innerHTML='<div class="loading">Buscando…</div>';
  try{const rows=await rpc('barberium_staff_search_customers',{p_query:q});$('#customerResults').innerHTML=rows.length?rows.map(c=>`<button type="button" class="customer-result" data-customer-id="${c.id}"><strong>${esc(c.name)}</strong><small>${c.phone?esc(c.phone):(c.has_phone?'WhatsApp já cadastrado ✓':'Sem WhatsApp cadastrado')}</small></button>`).join(''):'<div class="empty">Nenhum cliente encontrado.</div>';$$('[data-customer-id]').forEach(b=>b.onclick=()=>{const c=rows.find(x=>x.id===b.dataset.customerId);st.customer=c;st.newCustomer=false;$('#selectedCustomerWrap').innerHTML=`<div class="selected-customer"><strong>${esc(c.name)}</strong><small>${c.phone?esc(c.phone):(c.has_phone?'WhatsApp já cadastrado ✓':'Sem WhatsApp cadastrado')}</small></div>`;$('#customerResults').innerHTML='';$('#newCustomerFields').classList.add('hidden')})}catch(e){$('#customerResults').innerHTML=`<div class="empty">${esc(friendlyError(e))}</div>`}
}
async function refreshBookingDynamic(st,initial=false){renderAddonOptions(st);syncPrice(st,!initial);await refreshSlots(st)}
function renderAddonOptions(st){const s=serviceById(st.serviceId);const wrap=$('#addonOptions');if(!wrap)return;wrap.innerHTML=s?.addons?.length?s.addons.map(a=>`<label class="check-row"><input type="checkbox" value="${a.service_id}" ${st.addonIds.includes(a.service_id)?'checked':''} ${st.edit&&!isManager()&&!can('edit_addons')?'disabled':''}><span>${esc(a.name)} · +${moneyCents(a.price_cents)}</span></label>`).join(''):'<div class="empty">Este serviço não possui adicionais.</div>';$$('#addonOptions input').forEach(i=>i.onchange=()=>{st.addonIds=$$('#addonOptions input:checked').map(x=>x.value);syncPrice(st,true);refreshSlots(st)})}
function syncPrice(st,resetFinal){const listed=calcListed(st.serviceId,st.addonIds);if($('#listedPrice'))$('#listedPrice').textContent=moneyCents(listed);if(resetFinal&&(isManager()||can('edit_value'))&&$('#finalPrice')){$('#finalPrice').value=(listed/100).toFixed(2);st.manualPriceCents=listed}}
async function refreshSlots(st){const sel=$('#bookingTime');if(!sel||!st.professionalId||!st.serviceId||!st.date)return;const keep=st.time;sel.innerHTML='<option value="">Carregando…</option>';try{let slots=await rpc('barberium_staff_available_slots',{p_professional_id:st.professionalId,p_service_id:st.serviceId,p_addon_service_ids:st.addonIds,p_date:st.date,p_exclude_appointment_id:st.edit?st.detail.id:null});if(keep&&!slots.includes(keep))slots=[keep,...slots].sort();sel.innerHTML=slots.length?`<option value="">Selecione</option>${slots.map(t=>`<option value="${t}" ${t===keep?'selected':''}>${t}</option>`).join('')}`:'<option value="">Sem horários livres</option>';sel.onchange=e=>st.time=e.target.value}catch(e){sel.innerHTML='<option value="">Erro ao carregar</option>'}}
async function saveBooking(e,st){
  e.preventDefault();const btn=$('#saveBooking');btn.disabled=true;btn.textContent='Salvando…';
  try{
    const time=$('#bookingTime').value;if(!time)throw new Error('Escolha um horário.');
    const finalInput=$('#finalPrice');const finalCents=finalInput?Math.round((Number(finalInput.value)||0)*100):null;
    const note=$('#internalNote')?.value||null;
    if(st.edit){
      await rpc('barberium_staff_update_appointment',{p_appointment_id:st.detail.id,p_professional_id:$('#bookingProfessional').value,p_service_id:$('#bookingService').value,p_addon_service_ids:st.addonIds,p_date:$('#bookingDate').value,p_time:time,p_final_price_cents:finalCents,p_internal_note:note});
      toast('Atendimento atualizado.');closeModal();await loadAgenda();
    }else{
      let customerId=st.customer?.id||null,fullName=null,phone=null;
      if(!customerId){if(!st.newCustomer)throw new Error('Selecione um cliente ou crie um novo.');fullName=$('#newCustomerName').value.trim();phone=$('#newCustomerPhone').value.trim()}
      await rpc('barberium_staff_create_appointment',{p_customer_id:customerId,p_full_name:fullName,p_phone:phone,p_professional_id:$('#bookingProfessional').value,p_service_id:$('#bookingService').value,p_addon_service_ids:st.addonIds,p_date:$('#bookingDate').value,p_time:time,p_final_price_cents:finalCents,p_internal_note:note});
      toast('Agendamento criado.');closeModal();await loadAgenda();
    }
  }catch(err){toast(friendlyError(err));btn.disabled=false;btn.textContent=st.edit?'Salvar alterações':'Criar agendamento'}
}

function openBlockDetail(id,kind){const b=(currentAgenda?.blocks||[]).find(x=>x.id===id&&x.block_type===kind);if(!b)return;const pt=partsSP(b.starts_at);const canEdit=isManager()||(kind==='recurring'?can('create_recurring_block'):can('create_block'));openModal('BLOQUEIO',b.reason||'Horário bloqueado',`<div class="detail-grid"><div class="detail-box"><small>Profissional</small><strong>${esc(b.professional)}</strong></div><div class="detail-box"><small>Tipo</small><strong>${kind==='recurring'?'Recorrente':'Pontual'}</strong></div><div class="detail-box"><small>Data</small><strong>${dateShort(pt.date)}</strong></div><div class="detail-box"><small>Horário</small><strong>${pt.time}–${timeBR(b.ends_at)}</strong></div>${b.ends_on?`<div class="detail-box wide"><small>Repete até</small><strong>${esc(b.ends_on)}</strong></div>`:''}</div>${canEdit?`<div class="action-row"><button id="editBlock" class="soft-btn">Editar</button><button id="deleteBlock" class="danger-btn">Remover</button></div>`:''}`);$('#editBlock')?.addEventListener('click',()=>openBlockModal('edit',b));$('#deleteBlock')?.addEventListener('click',()=>deleteBlock(b))}
function openBlockModal(mode,b=null){
  const edit=mode==='edit';const kind=edit?b.block_type:null;const pt=edit?partsSP(b.starts_at):{date:currentDate,time:'12:00'};const end=edit?timeBR(b.ends_at):'13:00';const proId=edit?b.professional_id:(isManager()?(filterProfessionalId||catalog.professionals[0]?.id):member.professional_id);
  const allowRecurring=isManager()||can('create_recurring_block');const allowSingle=isManager()||can('create_block');
  openModal(edit?'EDITAR BLOQUEIO':'NOVO BLOQUEIO',edit?(b.reason||'Bloqueio'):'Bloquear horário',`<form id="blockForm" class="form-grid"><section class="form-section"><div class="field"><label>Profissional</label><select id="blockProfessional" ${isManager()?'':'disabled'}>${catalog.professionals.map(p=>`<option value="${p.id}" ${p.id===proId?'selected':''}>${esc(p.name)}</option>`).join('')}</select></div><div class="form-grid two"><div class="field"><label>${kind==='recurring'?'Inicia em':'Data'}</label><input id="blockDate" type="date" value="${pt.date}"></div><div class="field"><label>Motivo</label><input id="blockReason" value="${esc(edit?(b.reason||''):'')}"></div><div class="field"><label>Início</label><input id="blockStart" type="time" value="${pt.time}"></div><div class="field"><label>Fim</label><input id="blockEnd" type="time" value="${end}"></div></div>${!edit&&allowRecurring?`<label class="switch-row"><div><strong>Bloqueio recorrente</strong><small>Repete toda semana neste dia.</small></div><input id="blockRecurring" type="checkbox" ${!allowSingle?'checked':''}></label>`:''}<div id="blockEndDateWrap" class="field ${kind==='recurring'?'':'hidden'}"><label>Repetir até (opcional)</label><input id="blockEndsOn" type="date" value="${edit&&b.ends_on?b.ends_on:''}"></div></section><button class="gold-btn" id="saveBlock" type="submit">${edit?'Salvar bloqueio':'Criar bloqueio'}</button></form>`);
  $('#blockRecurring')?.addEventListener('change',e=>$('#blockEndDateWrap').classList.toggle('hidden',!e.target.checked));
  $('#blockForm').onsubmit=async e=>{e.preventDefault();const btn=$('#saveBlock');btn.disabled=true;btn.textContent='Salvando…';try{const recurring=edit?kind==='recurring':($('#blockRecurring')?.checked||false);const payload={p_professional_id:$('#blockProfessional').value,p_date:$('#blockDate').value,p_start_time:$('#blockStart').value,p_end_time:$('#blockEnd').value,p_reason:$('#blockReason').value.trim()||null,p_ends_on:recurring?($('#blockEndsOn').value||null):null};if(edit)await rpc('barberium_staff_update_block',{p_block_id:b.id,p_kind:kind,...payload});else await rpc('barberium_staff_create_block',{...payload,p_recurring:recurring});toast('Bloqueio salvo.');closeModal();await loadAgenda()}catch(err){toast(friendlyError(err));btn.disabled=false;btn.textContent=edit?'Salvar bloqueio':'Criar bloqueio'}}
}
async function deleteBlock(b){if(!confirm(`Remover este ${b.recurring?'bloqueio recorrente':'bloqueio'}?`))return;try{await rpc('barberium_staff_delete_block',{p_block_id:b.id,p_kind:b.block_type});toast('Bloqueio removido.');closeModal();await loadAgenda()}catch(e){toast(friendlyError(e))}}

function periodRange(kind){const now=new Date();now.setHours(12,0,0,0);if(kind==='today'){const x=isoDate(now);return[x,x]}if(kind==='week'){const d=new Date(now),day=d.getDay(),diff=day===0?-6:1-day;d.setDate(d.getDate()+diff);const e=new Date(d);e.setDate(e.getDate()+6);return[isoDate(d),isoDate(e)]}return[isoDate(new Date(now.getFullYear(),now.getMonth(),1,12)),isoDate(new Date(now.getFullYear(),now.getMonth()+1,0,12))]}
async function loadPerformance(){if(!can('view_own_revenue'))return;const[start,end]=periodRange(activePeriod);$('#periodLabel').textContent=start===end?dateLong(start):`${dateShort(start)} — ${dateShort(end)}`;$('#performanceCards').innerHTML='<div class="loading" style="grid-column:1/-1">Carregando…</div>';$('#servicesPerformance').innerHTML='<div class="loading">Carregando…</div>';try{const d=await rpc('barberium_staff_performance',{p_start_date:start,p_end_date:end}),s=d.summary||{};$('#performanceCards').innerHTML=`<article class="performance-card gold"><small>Faturamento realizado</small><strong>${moneyCents(s.realized_revenue_cents)}</strong><em>Horários concluídos</em></article><article class="performance-card"><small>Ainda agendado</small><strong>${moneyCents(s.scheduled_revenue_cents)}</strong><em>Horários confirmados</em></article><article class="performance-card"><small>Atendimentos</small><strong>${s.completed||0}</strong><em>Concluídos</em></article><article class="performance-card"><small>Ticket médio</small><strong>${moneyCents(s.average_ticket_cents)}</strong><em>Sobre concluídos</em></article>`;$('#servicesPerformance').innerHTML=d.services?.length?d.services.map(x=>`<article class="service-stat"><div><h3>${esc(x.service)}</h3><p>${x.appointments} horários • ${x.completed} concluídos</p></div><strong>${moneyCents((x.realized_revenue_cents||0)+(x.scheduled_revenue_cents||0))}</strong></article>`).join(''):'<div class="empty">Nenhum atendimento neste período.</div>'}catch(e){$('#performanceCards').innerHTML=`<div class="empty" style="grid-column:1/-1">${esc(friendlyError(e))}</div>`}}

const ACTION_PERMISSIONS=[['create_appointment','Criar agendamentos'],['cancel_appointment','Cancelar agendamentos'],['edit_service','Alterar serviço'],['edit_addons','Alterar adicionais'],['edit_date','Alterar data'],['edit_time','Alterar horário'],['edit_value','Alterar valor'],['create_block','Criar/editar bloqueio pontual'],['create_recurring_block','Criar/editar bloqueio recorrente'],['edit_internal_note','Adicionar/editar observação interna'],['mark_completed','Marcar como concluído'],['mark_no_show','Marcar como não compareceu'],['leave_payment_pending','Deixar pagamento pendente'],['register_expense','Registrar despesas'],['cash_withdrawal','Registrar sangria'],['cash_supply','Registrar suprimento'],['open_cash','Abrir caixa'],['close_cash','Fechar caixa'],['confirm_membership_payment','Confirmar pagamentos de planos']];
const VIEW_PERMISSIONS=[['view_phone','Ver WhatsApp do cliente'],['view_full_name','Ver nome completo'],['view_value','Ver valor do atendimento'],['view_internal_note','Ver observação interna'],['view_customer_history','Ver histórico/resumo do cliente'],['view_birthday','Ver aniversário'],['view_own_revenue','Ver o próprio faturamento'],['view_own_commission','Ver as próprias comissões']];
async function loadTeam(){if(!isManager())return;$('#teamList').innerHTML='<div class="loading">Carregando equipe…</div>';try{const team=await rpc('barberium_staff_team');$('#teamList').innerHTML=team.map(p=>`<article class="team-card"><img src="../${esc(p.image_path||'assets/logo-sb.webp')}" alt=""><div class="team-info"><h3>${esc(p.name)}</h3><p>${p.login_active?`Login: ${esc(p.login_email||'ativo')}`:'Sem login vinculado'}</p></div><button class="soft-btn" data-permissions="${p.professional_id}">Permissões</button></article>`).join('');$$('[data-permissions]').forEach(b=>b.onclick=()=>openPermissions(team.find(x=>x.professional_id===b.dataset.permissions)))}catch(e){$('#teamList').innerHTML=`<div class="empty">${esc(friendlyError(e))}</div>`}}
function openPermissions(p){openModal('PERMISSÕES',p.name,`<div class="permission-groups"><section class="permission-group"><h3>Ações</h3><div class="permission-list">${ACTION_PERMISSIONS.map(([k,l])=>permRow(k,l,p.permissions?.[k])).join('')}</div></section><section class="permission-group"><h3>Visualização</h3><div class="permission-list">${VIEW_PERMISSIONS.map(([k,l])=>permRow(k,l,p.permissions?.[k])).join('')}</div></section><button id="savePermissions" class="gold-btn">Salvar permissões</button></div>`);$('#savePermissions').onclick=async()=>{const btn=$('#savePermissions');btn.disabled=true;btn.textContent='Salvando…';const perms={};$$('[data-perm]').forEach(i=>perms[i.dataset.perm]=i.checked);try{await rpc('barberium_staff_set_permissions',{p_professional_id:p.professional_id,p_permissions:perms});toast('Permissões atualizadas.');closeModal();loadTeam()}catch(e){toast(friendlyError(e));btn.disabled=false;btn.textContent='Salvar permissões'}}}
function permRow(k,label,on){return `<label class="permission-item"><span>${esc(label)}</span><input data-perm="${k}" type="checkbox" ${on?'checked':''}></label>`}


/* =========================
   CLIENTES · v10
========================= */
let currentClientTab='base';
let clientBaseFilter='all';
let clientsCache=[];
let clientReportsCache=null;
let birthdayPeriod='today';
let campaignAudienceRows=[];
let campaignTemplatesCache=[];

function brDateOnly(v){if(!v)return'—';const s=String(v).slice(0,10);const [y,m,d]=s.split('-');return y&&m&&d?`${d}/${m}/${y}`:s}
function monthLabel(v){if(!v)return'';return new Intl.DateTimeFormat('pt-BR',{month:'short',year:'numeric'}).format(new Date(`${String(v).slice(0,10)}T12:00:00`)).replace(/\./g,'')}
function phoneLabel(c){return c.phone?c.phone:(c.has_phone?'WhatsApp já cadastrado ✓':'Sem telefone')}

function switchClientTab(tab){
  currentClientTab=tab;
  $$('[data-client-tab]').forEach(b=>b.classList.toggle('active',b.dataset.clientTab===tab));
  $('#clientBaseTab').classList.toggle('hidden',tab!=='base');
  $('#clientReportsTab').classList.toggle('hidden',tab!=='reports');
  $('#clientCampaignsTab').classList.toggle('hidden',tab!=='campaigns');
  if(tab==='base')loadClients();
  if(tab==='reports')loadClientReports();
  if(tab==='campaigns'){loadCampaignTemplates();loadCampaignHistory()}
}

async function loadClients(){
  if(!isManager())return;
  const q=$('#clientSearch')?.value?.trim()||'';
  $('#clientList').innerHTML='<div class="loading">Carregando clientes…</div>';
  try{
    clientsCache=await rpc('barberium_staff_customers',{p_query:q,p_without_phone:clientBaseFilter==='without_phone'});
    renderClientList();
  }catch(e){$('#clientList').innerHTML=`<div class="empty">${esc(friendlyError(e))}</div>`}
}
function renderClientList(){
  if(!clientsCache.length){$('#clientList').innerHTML='<div class="empty">Nenhum cliente encontrado.</div>';return}
  $('#clientList').innerHTML=clientsCache.map(c=>`<button class="client-card ${c.phone?'':'missing-phone'}" data-client-id="${c.id}" type="button"><h3>${esc(c.name)}</h3><p>${c.phone?esc(c.phone):'Sem telefone'}${c.main_unit?` • ${esc(c.main_unit)}`:''}</p><div class="client-meta"><span>Último atendimento: ${c.last_visit?dateTimeBR(c.last_visit):'—'}</span>${c.completed?`<span>${c.completed} concluído${c.completed===1?'':'s'}</span>`:''}</div></button>`).join('');
  $$('[data-client-id]').forEach(b=>b.onclick=()=>openClientDetail(b.dataset.clientId));
}

async function openClientDetail(id){
  openModal('CLIENTE','Carregando…','<div class="loading">Buscando ficha…</div>');
  try{const d=await rpc('barberium_staff_customer_detail',{p_customer_id:id});renderClientDetail(d)}catch(e){$('#modalBody').innerHTML=`<div class="empty">${esc(friendlyError(e))}</div>`}
}
function renderClientDetail(d){
  $('#modalTitle').textContent=d.name;
  const s=d.stats||{};
  const history=(d.history||[]).map(h=>`<article class="customer-history-item"><strong>${esc(h.service)} • ${esc(h.professional)}</strong><p>${dateTimeBR(h.starts_at)} • ${esc(h.unit||'')} • ${moneyCents(h.total_price_cents)}</p><span class="status ${h.status}">${statusLabel(h.status)}</span></article>`).join('')||'<div class="empty">Nenhum atendimento registrado.</div>';
  const units=(d.visits_by_unit||[]).map(u=>`<div class="unit-breakdown-row"><span>${esc(u.unit)}</span><strong>${u.visits} visitas • ${moneyCents(u.spent_cents)}</strong></div>`).join('')||'<div class="empty">Sem visitas concluídas.</div>';
  $('#modalBody').innerHTML=`
    <div class="detail-grid">
      <div class="detail-box wide"><small>WhatsApp</small><strong>${d.phone?esc(d.phone):'Sem telefone'}</strong></div>
      <div class="detail-box"><small>Aniversário</small><strong>${d.birthday?brDateOnly(d.birthday):'—'}</strong></div>
      <div class="detail-box"><small>Unidade principal</small><strong>${esc(d.main_unit||'Automática')}</strong></div>
      <div class="detail-box"><small>Primeira unidade</small><strong>${esc(d.first_unit||'—')}</strong></div>
      <div class="detail-box"><small>Última unidade</small><strong>${esc(d.last_unit||'—')}</strong></div>
    </div>
    ${d.persistent_note?`<div class="detail-note"><small>OBSERVAÇÃO DO CLIENTE</small><p>${esc(d.persistent_note)}</p></div>`:''}
    <div class="detail-grid">
      <div class="detail-box"><small>Atendimentos</small><strong>${s.appointments||0}</strong></div>
      <div class="detail-box"><small>Concluídos</small><strong>${s.completed||0}</strong></div>
      <div class="detail-box"><small>Cancelamentos</small><strong>${s.cancelled||0}</strong></div>
      <div class="detail-box"><small>Faltas</small><strong>${s.no_show||0}</strong></div>
      <div class="detail-box"><small>Total gasto</small><strong>${moneyCents(s.spent_cents)}</strong></div>
      <div class="detail-box"><small>Ticket médio</small><strong>${moneyCents(s.average_ticket_cents)}</strong></div>
      <div class="detail-box"><small>Última visita</small><strong>${s.last_visit?dateTimeBR(s.last_visit):'—'}</strong></div>
      <div class="detail-box"><small>Próximo horário</small><strong>${s.next_visit?dateTimeBR(s.next_visit):'—'}</strong></div>
    </div>
    <div class="action-row">${d.phone?`<a class="soft-btn" href="https://wa.me/${String(d.phone).replace(/\D/g,'')}" target="_blank" rel="noopener">Abrir WhatsApp</a>`:''}<button id="editClientButton" class="soft-btn" type="button">Editar cliente</button><button id="assignMembershipButton" class="gold-btn" type="button">+ Assinatura/Pacote</button></div>
    <h3 class="section-mini-title">Assinaturas e pacotes</h3><div id="clientMemberships"><div class="loading">Carregando planos…</div></div>
    <h3 class="section-mini-title">Por unidade</h3><div class="unit-breakdown">${units}</div>
    <h3 class="section-mini-title">Histórico de atendimentos</h3><div class="customer-history">${history}</div>`;
  window.__currentClientId=d.id;$('#editClientButton').onclick=()=>openEditClient(d);$('#assignMembershipButton').onclick=()=>openAssignMembership(d.id);loadClientMemberships(d.id);
}
function openEditClient(d){
  const units=[`<option value="">Automática</option>`,...(catalog.units||[]).map(u=>`<option value="${u.id}" ${u.id===d.preferred_unit_id?'selected':''}>${esc(u.name)}</option>`)].join('');
  openModal('EDITAR CLIENTE',d.name,`<form id="editClientForm" class="form-grid"><div class="field"><label>Nome completo</label><input id="editClientName" value="${esc(d.name)}" required></div><div class="field"><label>WhatsApp</label><input id="editClientPhone" inputmode="tel" value="${esc(d.phone||'')}" placeholder="(11) 99999-9999"></div><div class="field"><label>Aniversário</label><input id="editClientBirthday" type="date" value="${esc(d.birthday||'')}"></div><div class="field"><label>Unidade principal</label><select id="editClientUnit">${units}</select></div><div class="field"><label>Observação permanente</label><textarea id="editClientNote" placeholder="Preferências e informações internas">${esc(d.persistent_note||'')}</textarea></div><button id="saveClientButton" class="gold-btn" type="submit">Salvar cliente</button></form>`);
  $('#editClientForm').onsubmit=async e=>{e.preventDefault();const btn=$('#saveClientButton');btn.disabled=true;btn.textContent='Salvando…';try{const r=await rpc('barberium_staff_update_customer',{p_customer_id:d.id,p_full_name:$('#editClientName').value.trim(),p_phone:$('#editClientPhone').value.trim(),p_birthday:$('#editClientBirthday').value||null,p_preferred_unit_id:$('#editClientUnit').value||null,p_persistent_note:$('#editClientNote').value.trim()||null});toast(r.merged?'Cadastros mesclados e atualizados.':'Cliente atualizado.');closeModal();await loadClients()}catch(err){toast(friendlyError(err));btn.disabled=false;btn.textContent='Salvar cliente'}};
}

async function loadClientReports(){
  if(!isManager())return;
  $('#clientReportSummary').innerHTML='<div class="loading" style="grid-column:1/-1">Carregando relatórios…</div>';
  try{clientReportsCache=await rpc('barberium_staff_client_reports',{p_months:6});renderClientReports()}catch(e){$('#clientReportSummary').innerHTML=`<div class="empty" style="grid-column:1/-1">${esc(friendlyError(e))}</div>`}
}
function renderClientReports(){
  const d=clientReportsCache||{},s=d.summary||{};
  $('#clientReportSummary').innerHTML=`<article class="summary-card"><small>Clientes</small><strong>${s.customers||0}</strong></article><article class="summary-card gold"><small>Ticket médio</small><strong>${moneyCents(s.average_ticket_cents)}</strong></article><article class="summary-card"><small>Faturamento histórico</small><strong>${moneyCents(s.spent_cents)}</strong></article>`;
  renderBirthdays();
  $('#evolutionList').innerHTML=(d.evolution||[]).map(x=>`<article class="report-row"><div><h3>${esc(monthLabel(x.month))}</h3><p>Base ${x.customers_total} • +${x.new_customers} novos • ${x.completed} concluídos</p></div><div><strong>${moneyCents(x.revenue_cents)}</strong><div class="report-values"><span>Ticket ${moneyCents(x.ticket_cents)}</span></div></div></article>`).join('')||'<div class="empty">Sem dados.</div>';
  $('#reportProfessional').innerHTML=(catalog.professionals||[]).map(p=>`<option value="${p.id}">${esc(p.name)}</option>`).join('');
  $('#reportProfessional').onchange=renderProfessionalComparison;
  renderProfessionalComparison();
}
function renderBirthdays(){
  const rows=clientReportsCache?.birthdays?.[birthdayPeriod]||[];
  $('#birthdayList').innerHTML=rows.length?rows.map(c=>`<article class="client-card birthday-card"><div><strong>${esc(c.name)}</strong><small>${c.birthday?` • ${brDateOnly(c.birthday)}`:''}</small></div><a href="https://wa.me/${String(c.phone).replace(/\D/g,'')}" target="_blank" rel="noopener">WhatsApp</a></article>`).join(''):'<div class="empty">Nenhum aniversariante neste período.</div>';
}
function renderProfessionalComparison(){
  const id=$('#reportProfessional')?.value||catalog.professionals?.[0]?.id;const rows=(clientReportsCache?.professionals||[]).filter(x=>x.professional_id===id);
  $('#professionalComparison').innerHTML=rows.length?rows.map(x=>{const denom=(x.new_clients||0)+(x.returning_clients||0),rate=denom?Math.round((x.returning_clients||0)*100/denom):0;return `<article class="report-row"><div><h3>${esc(monthLabel(x.month))}</h3><p>${x.completed} concluídos • ${x.customers} clientes • ${x.new_clients} novos • ${x.returning_clients} retornos • retorno ${rate}%</p><p>${x.cancelled} cancelamentos • ${x.no_show} faltas</p></div><div><strong>${moneyCents(x.revenue_cents)}</strong><div class="report-values"><span>Ticket ${moneyCents(x.ticket_cents)}</span></div></div></article>`}).join(''):'<div class="empty">Sem dados para este profissional.</div>';
}

async function loadCampaignAudience(){
  $('#campaignSelection').innerHTML='<div class="loading">Carregando clientes…</div>';
  try{campaignAudienceRows=await rpc('barberium_staff_campaign_audience',{p_audience:$('#campaignAudience').value});renderCampaignSelection()}catch(e){$('#campaignSelection').innerHTML=`<div class="empty">${esc(friendlyError(e))}</div>`}
}
function renderCampaignSelection(){
  if(!campaignAudienceRows.length){$('#campaignSelection').innerHTML='<div class="empty">Nenhum cliente neste público.</div>';return}
  $('#campaignSelection').innerHTML=`<div class="campaign-select-head"><small>${campaignAudienceRows.length} cliente${campaignAudienceRows.length===1?'':'s'}</small><button id="toggleAllCampaign" class="soft-btn" type="button">Desmarcar todos</button></div>${campaignAudienceRows.map(c=>`<label class="campaign-person"><input data-campaign-customer type="checkbox" value="${c.id}" checked><div><strong>${esc(c.name)}</strong><small>${c.days_absent!=null?`${c.days_absent} dias sem vir`:c.birthday?`Aniversário ${brDateOnly(c.birthday)}`:''}${c.unit?` • ${esc(c.unit)}`:''}</small></div></label>`).join('')}`;
  $('#toggleAllCampaign').onclick=()=>{const boxes=$$('[data-campaign-customer]');const anyUnchecked=boxes.some(x=>!x.checked);boxes.forEach(x=>x.checked=anyUnchecked);$('#toggleAllCampaign').textContent=anyUnchecked?'Desmarcar todos':'Selecionar todos'};
}
function selectedCampaignIds(){return $$('[data-campaign-customer]:checked').map(x=>x.value)}
function campaignPreviewMessage(c){let msg=$('#campaignMessage').value||'';if($('#campaignMessageMode').value==='personalized'){msg=msg.replaceAll('{nome}',(c.name||'').split(' ')[0]).replaceAll('{dias_sem_vir}',c.days_absent??'').replaceAll('{unidade}',c.unit||'')}return msg}
function previewCampaign(){const ids=selectedCampaignIds();if(!ids.length){toast('Selecione ao menos um cliente.');return}const rows=campaignAudienceRows.filter(c=>ids.includes(c.id)).slice(0,3);openModal('PRÉVIA DA CAMPANHA','Como ficará',rows.map(c=>`<article class="campaign-recipient"><strong>${esc(c.name)}</strong><p>${esc(campaignPreviewMessage(c))}</p></article>`).join(''))}
async function loadCampaignTemplates(){if(!isManager())return;try{campaignTemplatesCache=await rpc('barberium_staff_campaign_templates');$('#campaignTemplate').innerHTML='<option value="">Nenhum modelo</option>'+campaignTemplatesCache.map(t=>`<option value="${t.id}">${esc(t.name)}</option>`).join('')}catch(e){console.error(e)}}
async function saveCampaignTemplate(){const message=$('#campaignMessage').value.trim();if(!message){toast('Escreva a mensagem primeiro.');return}const name=prompt('Nome deste modelo:');if(!name)return;try{await rpc('barberium_staff_save_campaign_template',{p_name:name,p_message:message});toast('Modelo salvo.');await loadCampaignTemplates()}catch(e){toast(friendlyError(e))}}
async function createCampaign(schedule){
  const ids=selectedCampaignIds(),message=$('#campaignMessage').value.trim();if(!ids.length){toast('Selecione ao menos um cliente.');return}if(!message){toast('Escreva a mensagem.');return}
  let scheduledAt=null;if(schedule){const v=$('#campaignSchedule').value;if(!v){toast('Escolha data e horário do envio.');return}scheduledAt=new Date(v).toISOString()}
  try{const r=await rpc('barberium_staff_create_campaign',{p_title:$('#campaignTitle').value.trim()||'Campanha',p_audience:$('#campaignAudience').value,p_message_mode:$('#campaignMessageMode').value,p_message_template:message,p_scheduled_at:scheduledAt,p_customer_ids:ids});toast(schedule?'Campanha agendada.':'Campanha preparada.');await loadCampaignHistory();await openCampaignDetail(r.campaign_id)}catch(e){toast(friendlyError(e))}
}
async function loadCampaignHistory(){if(!isManager())return;$('#campaignHistory').innerHTML='<div class="loading">Carregando campanhas…</div>';try{const rows=await rpc('barberium_staff_campaigns');$('#campaignHistory').innerHTML=rows.length?rows.map(c=>`<button class="campaign-card" data-campaign-id="${c.id}" type="button"><h3>${esc(c.title)}</h3><p>${c.recipients} destinatário${c.recipients===1?'':'s'} • ${c.scheduled_at?`Agendada: ${dateTimeBR(c.scheduled_at)}`:`Criada: ${dateTimeBR(c.created_at)}`}</p><div class="client-meta"><span class="status-${c.status}">${c.status==='scheduled'?'Agendada':c.status==='ready'?'Pronta':'Concluída'}</span></div></button>`).join(''):'<div class="empty">Nenhuma campanha criada.</div>';$$('[data-campaign-id]').forEach(b=>b.onclick=()=>openCampaignDetail(b.dataset.campaignId))}catch(e){$('#campaignHistory').innerHTML=`<div class="empty">${esc(friendlyError(e))}</div>`}}
async function openCampaignDetail(id){openModal('CAMPANHA','Carregando…','<div class="loading">Buscando campanha…</div>');try{const d=await rpc('barberium_staff_campaign_detail',{p_campaign_id:id});$('#modalTitle').textContent=d.title;$('#modalBody').innerHTML=`<div class="detail-grid"><div class="detail-box"><small>Status</small><strong>${d.status==='scheduled'?'Agendada':'Pronta'}</strong></div><div class="detail-box"><small>Destinatários</small><strong>${d.recipients?.length||0}</strong></div>${d.scheduled_at?`<div class="detail-box wide"><small>Programada para</small><strong>${dateTimeBR(d.scheduled_at)}</strong></div>`:''}</div><div class="detail-note"><small>MENSAGEM BASE</small><p>${esc(d.message_template)}</p></div><h3 class="section-mini-title">Destinatários</h3>${(d.recipients||[]).map(r=>`<article class="campaign-recipient ${r.returned?'returned':''}"><strong>${esc(r.name)}${r.returned?'<span class="returned-flag">Já retornou</span>':''}</strong><p>${esc(r.message)}</p><a href="https://wa.me/${String(r.phone).replace(/\D/g,'')}?text=${encodeURIComponent(r.message)}" target="_blank" rel="noopener">Abrir WhatsApp</a></article>`).join('')||'<div class="empty">Sem destinatários.</div>'}`;}catch(e){$('#modalBody').innerHTML=`<div class="empty">${esc(friendlyError(e))}</div>`}}

function downloadBlob(content,type,name){const blob=content instanceof Blob?content:new Blob([content],{type});const a=document.createElement('a');a.href=URL.createObjectURL(blob);a.download=name;document.body.appendChild(a);a.click();setTimeout(()=>{URL.revokeObjectURL(a.href);a.remove()},500)}
function csvCell(v){const s=String(v??'');return `"${s.replaceAll('"','""')}"`}
async function openExportClients(){openModal('EXPORTAR CLIENTES','Escolha o formato','<div class="export-options"><button class="soft-btn" data-export="csv">CSV</button><button class="soft-btn" data-export="txt">TXT</button><button class="soft-btn" data-export="pdf">PDF</button></div><p class="campaign-help">A exportação inclui toda a base de clientes da barbearia.</p>');$$('[data-export]').forEach(b=>b.onclick=()=>exportClients(b.dataset.export))}
async function exportClients(kind){try{const rows=await rpc('barberium_staff_customers',{p_query:'',p_without_phone:false});if(kind==='csv'){const head=['Nome','WhatsApp','Aniversário','Unidade principal','Último atendimento','Atendimentos','Concluídos','Total gasto','Observação'];const lines=[head,...rows.map(c=>[c.name,c.phone||'',c.birthday||'',c.main_unit||'',c.last_visit?dateTimeBR(c.last_visit):'',c.appointments||0,c.completed||0,(Number(c.spent_cents||0)/100).toFixed(2),c.persistent_note||''])].map(r=>r.map(csvCell).join(';'));downloadBlob('\ufeff'+lines.join('\n'),'text/csv;charset=utf-8','clientes-barberium.csv');toast('CSV gerado.')}else if(kind==='txt'){const text=rows.map(c=>`${c.name} | ${c.phone||'Sem telefone'} | ${c.birthday?brDateOnly(c.birthday):'Sem aniversário'} | ${c.main_unit||'Sem unidade'} | Total gasto: ${moneyCents(c.spent_cents)}`).join('\n');downloadBlob(text,'text/plain;charset=utf-8','clientes-barberium.txt');toast('TXT gerado.')}else{await exportClientsPdf(rows)}}catch(e){toast(friendlyError(e))}}
async function exportClientsPdf(rows){try{const mod=await import('https://cdn.jsdelivr.net/npm/jspdf@2.5.2/+esm');const {jsPDF}=mod;const doc=new jsPDF({unit:'mm',format:'a4'});let y=16;doc.setFontSize(16);doc.text('Scalabrini Barbieri — Base de clientes',14,y);y+=8;doc.setFontSize(9);doc.text(`Exportado em ${new Date().toLocaleString('pt-BR')} • ${rows.length} clientes`,14,y);y+=9;for(const c of rows){const line=`${c.name} | ${c.phone||'Sem telefone'} | ${c.main_unit||'Sem unidade'} | ${moneyCents(c.spent_cents)}`;const parts=doc.splitTextToSize(line,180);if(y+parts.length*5>286){doc.addPage();y=16}doc.text(parts,14,y);y+=parts.length*5+2}doc.save('clientes-barberium.pdf');toast('PDF gerado.')}catch(e){toast('Não foi possível gerar o PDF agora. Tente novamente com internet ativa.')}}

function normalizeHeader(v){return String(v||'').normalize('NFD').replace(/[\u0300-\u036f]/g,'').toLowerCase().replace(/[^a-z0-9]+/g,' ').trim()}
function parseCsvLine(line,delim){const out=[];let cur='',q=false;for(let i=0;i<line.length;i++){const ch=line[i];if(ch==='"'){if(q&&line[i+1]==='"'){cur+='"';i++}else q=!q}else if(ch===delim&&!q){out.push(cur.trim());cur=''}else cur+=ch}out.push(cur.trim());return out}
function dateImport(v){const s=String(v||'').trim();if(/^\d{4}-\d{2}-\d{2}$/.test(s))return s;const m=s.match(/^(\d{1,2})[\/\-.](\d{1,2})[\/\-.](\d{4})$/);return m?`${m[3]}-${pad(m[2])}-${pad(m[1])}`:''}
function rowsFromDelimited(text){const lines=text.split(/\r?\n/).map(x=>x.trim()).filter(Boolean);if(!lines.length)return[];const candidates=[';',',','\t'];const delim=candidates.sort((a,b)=>(lines[0].split(b).length-lines[0].split(a).length))[0];if(lines[0].split(delim).length<2)return lines.map(parseLooseLine).filter(x=>x.name);const raw=lines.map(l=>parseCsvLine(l,delim));const heads=raw[0].map(normalizeHeader);const aliases={name:['nome','cliente','nome completo','name','customer'],phone:['telefone','celular','whatsapp','fone','phone'],birthday:['aniversario','nascimento','data nascimento','birthday','data de nascimento'],note:['observacao','observacoes','nota','note']};const idx={};for(const [k,arr] of Object.entries(aliases)){idx[k]=heads.findIndex(h=>arr.some(a=>h===a||h.includes(a)))}if(idx.name<0)idx.name=0;return raw.slice(1).map(r=>({name:r[idx.name]||'',phone:idx.phone>=0?r[idx.phone]||'':'',birthday:idx.birthday>=0?dateImport(r[idx.birthday]):'',note:idx.note>=0?r[idx.note]||'':''})).filter(x=>x.name)}
function parseLooseLine(line){const phone=(line.match(/(?:\+?55\s*)?(?:\(?\d{2}\)?\s*)?9?\d{4}[-\s]?\d{4}/)||[])[0]||'';const birth=(line.match(/\b\d{1,2}[\/\-.]\d{1,2}[\/\-.]\d{4}\b/)||[])[0]||'';let name=line.replace(phone,'').replace(birth,'').replace(/[|;,\t]+/g,' ').replace(/\s{2,}/g,' ').trim();return{name,phone,birthday:dateImport(birth),note:''}}
async function pdfToLines(file){const pdfjs=await import('https://cdn.jsdelivr.net/npm/pdfjs-dist@4.10.38/build/pdf.min.mjs');pdfjs.GlobalWorkerOptions.workerSrc='https://cdn.jsdelivr.net/npm/pdfjs-dist@4.10.38/build/pdf.worker.min.mjs';const data=new Uint8Array(await file.arrayBuffer());const pdf=await pdfjs.getDocument({data}).promise;const lines=[];for(let p=1;p<=pdf.numPages;p++){const page=await pdf.getPage(p);const tc=await page.getTextContent();const groups=new Map();for(const it of tc.items){const y=Math.round(it.transform?.[5]||0);if(!groups.has(y))groups.set(y,[]);groups.get(y).push({x:it.transform?.[4]||0,s:it.str})}for(const [,items] of [...groups.entries()].sort((a,b)=>b[0]-a[0]))lines.push(items.sort((a,b)=>a.x-b.x).map(x=>x.s).join(' ').trim())}return lines.filter(Boolean)}
async function parseImportFile(file){const ext=(file.name.split('.').pop()||'').toLowerCase();if(ext==='pdf'){const lines=await pdfToLines(file);const maybe=rowsFromDelimited(lines.join('\n'));return maybe.length?maybe:lines.map(parseLooseLine).filter(x=>x.name)}const text=await file.text();return rowsFromDelimited(text)}
function openImportClients(){openModal('IMPORTAR CLIENTES','Trazer base de outro sistema','<div class="file-drop"><strong>CSV, TXT ou PDF</strong><input id="importClientFile" type="file" accept=".csv,.txt,.pdf,text/csv,text/plain,application/pdf"><small class="field-help">O Barberium identifica nome, WhatsApp e aniversário. Clientes sem telefone entram em “Sem telefone”.</small><button id="downloadImportModel" class="soft-btn" type="button">Baixar modelo CSV</button></div><div id="importPreview"></div>');$('#downloadImportModel').onclick=()=>downloadBlob('Nome;WhatsApp;Aniversário;Observação\nJoão Silva;(11) 99999-9999;1990-05-20;Cliente antigo','text/csv;charset=utf-8','modelo-clientes-barberium.csv');$('#importClientFile').onchange=async e=>{const file=e.target.files?.[0];if(!file)return;$('#importPreview').innerHTML='<div class="loading">Lendo arquivo…</div>';try{const rows=await parseImportFile(file);if(!rows.length)throw new Error('Nenhum cliente reconhecido no arquivo.');window.__barberiumImport={rows,fileName:file.name};$('#importPreview').innerHTML=`<p class="campaign-help">${rows.length} registros encontrados. Confira a prévia antes de importar.</p><div class="import-preview"><div class="import-row header"><span>Nome</span><span>WhatsApp</span><span>Aniversário</span></div>${rows.slice(0,12).map(r=>`<div class="import-row"><span>${esc(r.name)}</span><span>${esc(r.phone||'Sem telefone')}</span><span>${esc(r.birthday?brDateOnly(r.birthday):'—')}</span></div>`).join('')}</div><button id="confirmImportClients" class="gold-btn" type="button">Importar ${rows.length} clientes</button>`;$('#confirmImportClients').onclick=confirmImportClients}catch(err){$('#importPreview').innerHTML=`<div class="empty">${esc(friendlyError(err))}</div>`}}}
async function confirmImportClients(){const data=window.__barberiumImport;if(!data)return;const btn=$('#confirmImportClients');btn.disabled=true;btn.textContent='Importando…';try{const r=await rpc('barberium_staff_import_customers',{p_rows:data.rows,p_source:data.fileName});toast(`${r.inserted} novos • ${r.updated} atualizados • ${r.without_phone} sem telefone`);closeModal();clientBaseFilter='all';$$('[data-client-base-filter]').forEach(x=>x.classList.toggle('active',x.dataset.clientBaseFilter==='all'));await loadClients()}catch(e){toast(friendlyError(e));btn.disabled=false;btn.textContent='Tentar novamente'}}


/* =========================
   FINANCEIRO + PLANOS · v11
========================= */
let currentFinanceTab='overview';
let financeMonth=isoDate(new Date()).slice(0,7);
let financeBasis='cash';
let financeUnitId='';
let expenseStatusFilter='all';
let commissionTab='normal';
let financeSettingsCache=null;
let paymentOptionsCache={providers:[]};
let expenseCategoriesCache=[];
let membershipPlansCache=[];

function moneyToCents(v){const s=String(v??'').trim().replace(/[^0-9,.-]/g,'').replace(/\./g,'').replace(',','.');const n=Number(s);return Number.isFinite(n)?Math.round(n*100):0}
function centsInput(c=0){return ((Number(c)||0)/100).toFixed(2).replace('.',',')}
function financeMonthRange(){const [y,m]=financeMonth.split('-').map(Number);const last=new Date(y,m,0,12);return [`${y}-${pad(m)}-01`,isoDate(last)]}
function financeUnitOptions(includeAll=true){const opts=[];if(includeAll)opts.push('<option value="">Consolidado da empresa</option>');for(const u of (catalog.units||[]))opts.push(`<option value="${u.id}" ${financeUnitId===u.id?'selected':''}>${esc(u.name)}</option>`);return opts.join('')}
function providerOptions(selected=''){return `<option value="">Sem provedor</option>${(paymentOptionsCache.providers||[]).map(p=>`<option value="${p.id}" ${p.id===selected?'selected':''}>${esc(p.name)}</option>`).join('')}`}
function paymentMethodLabel(v){return({pix:'Pix',cash:'Dinheiro',debit:'Débito',credit:'Crédito'})[v]||v}
function financeStatusLabel(v){return({predicted:'Prevista',paid:'Paga',open:'Em aberto',partial:'Parcial',active:'Ativa',pending:'Pendente',paused:'Pausada',overdue:'Atrasada',cancelled:'Cancelada',expired:'Vencida'})[v]||v}

async function loadPaymentOptions(){try{paymentOptionsCache=await rpc('barberium_staff_payment_options')}catch{paymentOptionsCache={providers:[]}}}

function paymentLineHtml(index,amountCents=0){return `<div class="payment-line" data-payment-line="${index}">
  <div class="field"><label>Forma</label><select data-pay-method><option value="pix">Pix</option><option value="cash">Dinheiro</option><option value="debit">Débito</option><option value="credit">Crédito</option></select></div>
  <div class="field"><label>Valor</label><input data-pay-amount inputmode="decimal" value="${centsInput(amountCents)}"></div>
  <div class="field pay-provider hidden"><label>Provedor / maquininha</label><select data-pay-provider>${providerOptions()}</select></div>
  <div class="field pay-installments hidden"><label>Parcelas</label><select data-pay-installments>${Array.from({length:12},(_,i)=>`<option value="${i+1}">${i+1}x</option>`).join('')}</select></div>
  <div class="field pay-tender hidden"><label>Valor recebido</label><input data-pay-tender inputmode="decimal" value="${centsInput(amountCents)}"><small class="field-help" data-pay-change>Troco: R$ 0,00</small></div>
  ${index?'<button class="danger-btn small" data-remove-payment type="button">Remover</button>':''}
</div>`}
function wirePaymentLines(root,dueCents){
  const refresh=()=>{
    $$('[data-payment-line]',root).forEach(line=>{
      const method=$('[data-pay-method]',line).value;const amount=moneyToCents($('[data-pay-amount]',line).value);
      $('.pay-provider',line).classList.toggle('hidden',!['pix','debit','credit'].includes(method));
      $('.pay-installments',line).classList.toggle('hidden',method!=='credit');
      $('.pay-tender',line).classList.toggle('hidden',method!=='cash');
      if(method==='cash'){const tender=moneyToCents($('[data-pay-tender]',line).value);$('[data-pay-change]',line).textContent=`Troco: ${moneyCents(Math.max(0,tender-amount))}`}
    });
    const paid=$$('[data-pay-amount]',root).reduce((t,i)=>t+moneyToCents(i.value),0);const pending=moneyToCents($('#pendingAmount',root)?.value||0);
    $('#paymentBalance',root).textContent=`${moneyCents(paid)} recebido + ${moneyCents(pending)} pendente de ${moneyCents(dueCents)}`;
    $('#paymentBalance',root).classList.toggle('bad',paid+pending!==dueCents);
  };
  $$('[data-pay-method],[data-pay-amount],[data-pay-tender]',root).forEach(el=>{el.oninput=refresh;el.onchange=refresh});
  $$('[data-remove-payment]',root).forEach(b=>b.onclick=()=>{b.closest('[data-payment-line]').remove();refresh()});
  $('#pendingAmount',root)?.addEventListener('input',refresh);refresh();
}
async function openCompleteAppointment(id){
  openModal('CONCLUIR ATENDIMENTO','Pagamento','<div class="loading">Preparando pagamento…</div>');
  try{
    const [d,f]=await Promise.all([rpc('barberium_staff_appointment_detail',{p_appointment_id:id}),rpc('barberium_staff_appointment_finance',{p_appointment_id:id})]);await loadPaymentOptions();
    const total=Number(d.total_price_cents||f.total_price_cents||0),covered=Number(f.membership_covered_cents||0),due=Math.max(0,total-covered);let lineCounter=0;
    const uses=(f.uses||[]).length?`<div class="detail-note"><small>PLANO / PACOTE</small><p>${(f.uses||[]).map(u=>`${esc(u.plan)} • ${esc(u.service)}: ${moneyCents(u.coverage_cents)}`).join('<br>')}</p></div>`:'';
    const pendingAllowed=isManager()||can('leave_payment_pending');
    openModal('CONCLUIR ATENDIMENTO',d.customer.name,`${uses}<div class="detail-grid"><div class="detail-box"><small>Valor final</small><strong>${moneyCents(total)}</strong></div><div class="detail-box"><small>Coberto por plano</small><strong>${moneyCents(covered)}</strong></div><div class="detail-box wide"><small>A receber agora</small><strong>${moneyCents(due)}</strong></div></div>
      <div id="paymentLines">${due>0?paymentLineHtml(0,due):'<div class="empty">Nenhum valor avulso a receber. O atendimento será concluído pelo benefício do plano.</div>'}</div>
      ${due>0?'<button id="addPaymentLine" class="soft-btn" type="button">+ Dividir pagamento</button>':''}
      ${pendingAllowed&&due>0?`<h3 class="section-mini-title">Pagamento pendente</h3><div class="form-grid"><div class="field"><label>Valor que ficará pendente</label><input id="pendingAmount" inputmode="decimal" value="0,00"></div><div class="field"><label>Vencimento (opcional)</label><input id="pendingDueDate" type="date"></div><div class="field"><label>Observação</label><textarea id="pendingNote" placeholder="Ex.: acertar na próxima visita"></textarea></div></div>`:''}
      <div id="paymentBalance" class="payment-total"></div><button id="finishAppointmentPayment" class="gold-btn finance-wide" type="button">Concluir atendimento</button>`);
    const root=$('#modalBody');wirePaymentLines(root,due);
    $('#addPaymentLine')?.addEventListener('click',()=>{lineCounter++;$('#paymentLines').insertAdjacentHTML('beforeend',paymentLineHtml(lineCounter,0));wirePaymentLines(root,due)});
    $('#finishAppointmentPayment').onclick=async()=>{
      const payments=$$('[data-payment-line]',root).map(line=>{const method=$('[data-pay-method]',line).value;return{method,amount_cents:moneyToCents($('[data-pay-amount]',line).value),provider_id:$('[data-pay-provider]',line)?.value||null,installments:method==='credit'?Number($('[data-pay-installments]',line)?.value||1):1,tendered_cents:method==='cash'?moneyToCents($('[data-pay-tender]',line)?.value):null}}).filter(x=>x.amount_cents>0);
      const pending=moneyToCents($('#pendingAmount',root)?.value||0),sum=payments.reduce((t,x)=>t+x.amount_cents,0);if(sum+pending!==due){toast('A soma dos pagamentos e da pendência precisa fechar o valor a receber.');return}
      for(const p of payments){if(p.method==='cash'&&p.tendered_cents<p.amount_cents){toast('O valor recebido em dinheiro não pode ser menor que a parte em dinheiro.');return}}
      const btn=$('#finishAppointmentPayment');btn.disabled=true;btn.textContent='Concluindo…';
      try{await rpc('barberium_staff_complete_appointment',{p_appointment_id:id,p_payments:payments,p_pending_cents:pending,p_due_date:$('#pendingDueDate',root)?.value||null,p_note:$('#pendingNote',root)?.value?.trim()||null});toast('Atendimento concluído e financeiro registrado.');closeModal();await loadAgenda()}catch(e){toast(friendlyError(e));btn.disabled=false;btn.textContent='Concluir atendimento'}
    };
  }catch(e){$('#modalBody').innerHTML=`<div class="empty">${esc(friendlyError(e))}</div>`}
}

function switchFinanceTab(tab){currentFinanceTab=tab;$$('[data-finance-tab]').forEach(b=>b.classList.toggle('active',b.dataset.financeTab===tab));['overview','cash','expenses','commissions','plans'].forEach(x=>$(`#finance${x[0].toUpperCase()+x.slice(1)}Tab`)?.classList.toggle('hidden',x!==tab));if(tab==='overview')loadFinanceOverview();if(tab==='cash')loadCashStatus();if(tab==='expenses')loadExpenses();if(tab==='commissions')loadCommissions();if(tab==='plans')loadMembershipPlans()}
async function loadFinance(){
  $('#financeTitle').textContent=isManager()?'Financeiro':'Minhas comissões';$('#financeScope').textContent=isManager()?'Caixa, faturamento, despesas, comissões e planos.':'Acompanhe somente suas comissões e acertos.';
  $('#financeAdminControls').classList.toggle('hidden',!isManager());
  $$('[data-finance-tab]').forEach(b=>b.classList.toggle('hidden',!isManager()&&b.dataset.financeTab!=='commissions'));
  if(!isManager()){switchFinanceTab('commissions');return}
  if(!$('#financeUnit').options.length)$('#financeUnit').innerHTML=financeUnitOptions(true);$('#financeMonth').value=financeMonth;$('#financeBasis').value=financeBasis;await Promise.all([loadPaymentOptions(),loadFinanceSettings()]);switchFinanceTab(currentFinanceTab);
}
async function loadFinanceSettings(){if(!isManager())return;try{financeSettingsCache=await rpc('barberium_staff_finance_settings');const def=financeSettingsCache?.global?.dre_default_basis;if(def&& !$('#financeBasis')?.dataset.userChanged){financeBasis=def;$('#financeBasis').value=def}}catch(e){console.error(e)}}
async function loadFinanceOverview(){if(!isManager())return;const[start,end]=financeMonthRange();$('#financeSummary').innerHTML='<div class="loading">Carregando financeiro…</div>';try{const d=await rpc('barberium_staff_finance_overview',{p_start:start,p_end:end,p_unit_id:financeUnitId||null,p_basis:financeBasis});$('#financeSummary').innerHTML=`<article class="finance-kpi"><small>Receita bruta</small><strong>${moneyCents(d.gross_cents)}</strong></article><article class="finance-kpi negative"><small>Reembolsos</small><strong>${moneyCents(d.refunds_cents||0)}</strong></article><article class="finance-kpi"><small>Taxas</small><strong>${moneyCents(d.fees_cents)}</strong></article><article class="finance-kpi"><small>Líquido após estornos</small><strong>${moneyCents(d.net_received_cents)}</strong></article><article class="finance-kpi gold"><small>Resultado operacional</small><strong>${moneyCents(d.operating_result_cents)}</strong></article><article class="finance-kpi"><small>A receber</small><strong>${moneyCents(d.receivables_cents)}</strong></article>`;$('#financeDre').innerHTML=`<div class="dre-card"><div><span>Receita bruta</span><strong>${moneyCents(d.gross_cents)}</strong></div><div><span>− Reembolsos</span><strong>${moneyCents(d.refunds_cents||0)}</strong></div><div><span>− Taxas</span><strong>${moneyCents(d.fees_cents)}</strong></div><div><span>− Comissões</span><strong>${moneyCents(d.commissions_cents)}</strong></div><div><span>− Despesas pagas</span><strong>${moneyCents(d.expenses_cents)}</strong></div><div class="dre-result"><span>= Resultado operacional estimado</span><strong>${moneyCents(d.operating_result_cents)}</strong></div><small>Regime: ${financeBasis==='cash'?'Caixa':'Competência'}</small></div>`;$('#financeMethods').innerHTML=(d.by_method||[]).length?(d.by_method||[]).map(x=>`<article class="service-stat"><div><h3>${paymentMethodLabel(x.method)}</h3></div><strong>${moneyCents(x.amount_cents)}</strong></article>`).join(''):'<div class="empty">Nenhum recebimento no período.</div>';renderFinanceGoal(d)}catch(e){$('#financeSummary').innerHTML=`<div class="empty">${esc(friendlyError(e))}</div>`}}
function renderFinanceGoal(d){const pct=d.target_progress_percent;$('#financeGoalWrap').innerHTML=`<div class="section-head"><div><small>META DO MÊS</small><h2>Faturamento</h2></div><button id="setFinanceGoal" class="soft-btn" type="button">${d.revenue_target_cents?'Alterar meta':'Definir meta'}</button></div>${d.revenue_target_cents?`<div class="goal-card"><div><strong>${moneyCents(Number(d.gross_cents||0)-Number(d.refunds_cents||0))}</strong><span> de ${moneyCents(d.revenue_target_cents)}</span></div><div class="goal-track"><i style="width:${Math.min(100,Math.max(0,Number(pct)||0))}%"></i></div><small>${pct??0}% atingido</small></div>`:'<div class="empty">Nenhuma meta definida para este mês.</div>'}`;$('#setFinanceGoal').onclick=()=>openGoalModal(d.revenue_target_cents||0)}
function openGoalModal(current){openModal('META FINANCEIRA','Meta de faturamento',`<form id="goalForm" class="form-grid"><div class="field"><label>Meta do mês</label><input id="goalValue" inputmode="decimal" value="${centsInput(current)}"></div><button class="gold-btn" type="submit">Salvar meta</button></form>`);$('#goalForm').onsubmit=async e=>{e.preventDefault();try{await rpc('barberium_staff_save_financial_goal',{p_unit_id:financeUnitId||null,p_month:`${financeMonth}-01`,p_revenue_target_cents:moneyToCents($('#goalValue').value),p_net_target_cents:null});toast('Meta salva.');closeModal();loadFinanceOverview()}catch(err){toast(friendlyError(err))}}}

async function openFinanceSettings(){await loadFinanceSettings();const global=financeSettingsCache?.global||{};openModal('CONFIGURAÇÕES','Financeiro',`<form id="financeSettingsForm" class="form-grid"><div class="field"><label>Escopo</label><select id="settingsUnit">${financeUnitOptions(true)}</select></div><label class="permission-item"><span>Usar caixa diário neste escopo</span><input id="settingsCash" type="checkbox" ${global.use_cash_register?'checked':''}></label><div class="field"><label>Base padrão da comissão</label><select id="settingsCommissionBasis"><option value="gross" ${global.commission_basis!=='net'?'selected':''}>Valor bruto pago</option><option value="net" ${global.commission_basis==='net'?'selected':''}>Líquido após taxas</option></select></div><div class="field"><label>DRE padrão</label><select id="settingsDre"><option value="cash" ${global.dre_default_basis!=='accrual'?'selected':''}>Caixa</option><option value="accrual" ${global.dre_default_basis==='accrual'?'selected':''}>Competência</option></select></div><button class="gold-btn" type="submit">Salvar configurações</button></form><h3 class="section-mini-title">Provedores / maquininhas</h3><div id="providerSettingsList">${(financeSettingsCache?.providers||[]).map(p=>`<button class="client-card" data-edit-provider="${p.id}" type="button"><h3>${esc(p.name)}</h3><p>${p.is_active?'Ativo':'Inativo'} • ${(p.fees||[]).length} regras de taxa</p></button>`).join('')||'<div class="empty">Nenhum provedor cadastrado.</div>'}</div><button id="newProvider" class="soft-btn finance-wide" type="button">+ Cadastrar provedor</button>`);$('#settingsUnit').value=financeUnitId||'';$('#financeSettingsForm').onsubmit=saveFinanceSettings;$$('[data-edit-provider]').forEach(b=>b.onclick=()=>openProviderModal((financeSettingsCache.providers||[]).find(x=>x.id===b.dataset.editProvider)));$('#newProvider').onclick=()=>openProviderModal(null)}
async function saveFinanceSettings(e){e.preventDefault();try{await rpc('barberium_staff_save_finance_settings',{p_unit_id:$('#settingsUnit').value||null,p_use_cash_register:$('#settingsCash').checked,p_commission_basis:$('#settingsCommissionBasis').value,p_dre_default_basis:$('#settingsDre').value,p_settings:{}});toast('Configurações salvas.');closeModal();await loadFinanceSettings();loadFinanceOverview()}catch(err){toast(friendlyError(err))}}
function openProviderModal(p){const fees=p?.fees||[];const f=(method,inst=1)=>fees.find(x=>x.method===method&&Number(x.installments)===inst)||{};openModal('PROVEDOR',p?.name||'Novo provedor',`<form id="providerForm" class="form-grid"><div class="field"><label>Nome</label><input id="providerName" value="${esc(p?.name||'')}" required placeholder="Stone, Mercado Pago, InfinitePay..."></div><label class="permission-item"><span>Ativo</span><input id="providerActive" type="checkbox" ${p?.is_active===false?'':'checked'}></label><h3 class="section-mini-title">Taxas</h3><div class="rules-grid"><div class="field"><label>Pix %</label><input id="feePix" inputmode="decimal" value="${String(f('pix').percentage||0).replace('.',',')}"></div><div class="field"><label>Débito %</label><input id="feeDebit" inputmode="decimal" value="${String(f('debit').percentage||0).replace('.',',')}"></div>${[1,2,3,4,5,6,7,8,9,10,11,12].map(i=>`<div class="field"><label>Crédito ${i}x %</label><input data-credit-fee="${i}" inputmode="decimal" value="${String(f('credit',i).percentage||0).replace('.',',')}"></div>`).join('')}</div><button class="gold-btn" type="submit">Salvar provedor</button></form>`);$('#providerForm').onsubmit=async e=>{e.preventDefault();const rules=[{method:'pix',installments:1,percentage:Number($('#feePix').value.replace(',','.'))||0,fixed_fee_cents:0,is_active:true},{method:'debit',installments:1,percentage:Number($('#feeDebit').value.replace(',','.'))||0,fixed_fee_cents:0,is_active:true},...$$('[data-credit-fee]').map(i=>({method:'credit',installments:Number(i.dataset.creditFee),percentage:Number(i.value.replace(',','.'))||0,fixed_fee_cents:0,is_active:true}))];try{await rpc('barberium_staff_save_payment_provider',{p_provider_id:p?.id||null,p_name:$('#providerName').value.trim(),p_is_active:$('#providerActive').checked,p_fee_rules:rules});toast('Provedor salvo.');await loadPaymentOptions();await loadFinanceSettings();openFinanceSettings()}catch(err){toast(friendlyError(err))}}}

async function loadCashStatus(){if(!isManager())return;if(!financeUnitId){$('#cashStatus').innerHTML='<div class="empty">Selecione uma unidade acima para operar o caixa físico.</div>';return}$('#cashStatus').innerHTML='<div class="loading">Carregando caixa…</div>';try{const d=await rpc('barberium_staff_cash_status',{p_unit_id:financeUnitId});if(!d.open){$('#cashStatus').innerHTML=`<div class="cash-card"><span class="kicker">Caixa fechado</span><h2>Nenhum caixa aberto</h2><p>O caixa físico é opcional e separado por unidade.</p><button id="openCashButton" class="gold-btn" type="button">Abrir caixa</button></div>`;$('#openCashButton').onclick=openCashModal;return}$('#cashStatus').innerHTML=`<div class="cash-card"><span class="kicker">CAIXA ABERTO</span><div class="cash-balance"><small>Saldo esperado</small><strong>${moneyCents(d.expected_balance_cents)}</strong><span>Aberto em ${dateTimeBR(d.opened_at)} • Fundo ${moneyCents(d.opening_balance_cents)}</span></div><div class="cash-actions"><button class="soft-btn" data-cash-move="supply" type="button">+ Suprimento</button><button class="soft-btn" data-cash-move="withdrawal" type="button">− Sangria</button><button id="closeCashButton" class="gold-btn" type="button">Fechar caixa</button></div></div><h3 class="section-mini-title">Movimentos</h3><div class="cash-movements">${(d.movements||[]).map(x=>`<article><div><strong>${esc(x.type)}</strong><small>${dateTimeBR(x.created_at)}${x.note?` • ${esc(x.note)}`:''}</small></div><b>${x.amount_cents>=0?'+ ':''}${moneyCents(x.amount_cents)}</b></article>`).join('')||'<div class="empty">Sem movimentos.</div>'}</div>`;$$('[data-cash-move]').forEach(b=>b.onclick=()=>openCashMoveModal(b.dataset.cashMove));$('#closeCashButton').onclick=()=>openCloseCashModal(d)}catch(e){$('#cashStatus').innerHTML=`<div class="empty">${esc(friendlyError(e))}</div>`}}
function openCashModal(){openModal('CAIXA','Abrir caixa',`<form id="openCashForm" class="form-grid"><div class="field"><label>Fundo inicial</label><input id="openingBalance" inputmode="decimal" value="0,00"></div><button class="gold-btn" type="submit">Abrir caixa</button></form>`);$('#openCashForm').onsubmit=async e=>{e.preventDefault();try{await rpc('barberium_staff_open_cash',{p_unit_id:financeUnitId,p_opening_balance_cents:moneyToCents($('#openingBalance').value)});toast('Caixa aberto.');closeModal();loadCashStatus()}catch(err){toast(friendlyError(err))}}}
function openCashMoveModal(type){openModal(type==='supply'?'SUPRIMENTO':'SANGRIA',type==='supply'?'Adicionar dinheiro ao caixa':'Retirar dinheiro do caixa',`<form id="cashMoveForm" class="form-grid"><div class="field"><label>Valor</label><input id="cashMoveValue" inputmode="decimal" required></div><div class="field"><label>Observação</label><textarea id="cashMoveNote"></textarea></div><button class="gold-btn" type="submit">Registrar</button></form>`);$('#cashMoveForm').onsubmit=async e=>{e.preventDefault();try{await rpc('barberium_staff_cash_movement',{p_unit_id:financeUnitId,p_type:type,p_amount_cents:moneyToCents($('#cashMoveValue').value),p_note:$('#cashMoveNote').value.trim()||null});toast('Movimento registrado.');closeModal();loadCashStatus()}catch(err){toast(friendlyError(err))}}}
function openCloseCashModal(d){openModal('FECHAMENTO','Fechar caixa',`<form id="closeCashForm" class="form-grid"><div class="detail-note"><small>SALDO ESPERADO</small><p><strong>${moneyCents(d.expected_balance_cents)}</strong></p></div><div class="field"><label>Valor contado</label><input id="countedCash" inputmode="decimal" value="${centsInput(d.expected_balance_cents)}"></div><div class="field"><label>Justificativa se houver diferença</label><textarea id="cashCloseReason"></textarea></div><button class="gold-btn" type="submit">Confirmar fechamento</button></form>`);$('#closeCashForm').onsubmit=async e=>{e.preventDefault();try{const r=await rpc('barberium_staff_close_cash',{p_unit_id:financeUnitId,p_counted_cents:moneyToCents($('#countedCash').value),p_justification:$('#cashCloseReason').value.trim()||null});toast(`Caixa fechado. Diferença: ${moneyCents(r.difference_cents)}`);closeModal();loadCashStatus()}catch(err){toast(friendlyError(err))}}}

async function loadExpenseCategories(){try{expenseCategoriesCache=await rpc('barberium_staff_expense_categories')}catch{expenseCategoriesCache=[]}}
async function loadExpenses(){if(!isManager())return;const[start,end]=financeMonthRange();$('#expenseList').innerHTML='<div class="loading">Carregando despesas…</div>';await loadExpenseCategories();try{let rows=await rpc('barberium_staff_expenses',{p_start:start,p_end:end,p_unit_id:financeUnitId||null});if(expenseStatusFilter!=='all')rows=rows.filter(x=>x.status===expenseStatusFilter);$('#expenseList').innerHTML=rows.length?rows.map(e=>`<article class="plan-card"><div class="plan-head"><div><span class="plan-tag">${financeStatusLabel(e.status)}</span><h3>${esc(e.description)}</h3><p>${esc(e.category||'Sem categoria')} • ${esc(e.unit||'')}</p></div><strong>${moneyCents(e.amount_cents)}</strong></div><div class="plan-meta"><span>Vencimento: ${brDateOnly(e.due_date)}</span>${e.payment_method?`<span>${paymentMethodLabel(e.payment_method)}</span>`:''}${e.paid_from_cash?'<span>Pago pelo caixa</span>':''}</div></article>`).join(''):'<div class="empty">Nenhuma despesa no período.</div>'}catch(e){$('#expenseList').innerHTML=`<div class="empty">${esc(friendlyError(e))}</div>`}}
function openNewExpense(){if(!financeUnitId&&catalog.units?.length===1)financeUnitId=catalog.units[0].id;openModal('DESPESA','Nova despesa',`<form id="expenseForm" class="form-grid"><div class="field"><label>Unidade</label><select id="expenseUnit">${financeUnitOptions(false)}</select></div><div class="field"><label>Categoria</label><select id="expenseCategory"><option value="">Sem categoria</option>${expenseCategoriesCache.filter(x=>x.is_active).map(x=>`<option value="${x.id}">${esc(x.name)}</option>`).join('')}</select></div><div class="field"><label>Descrição</label><input id="expenseDescription" required></div><div class="field"><label>Valor</label><input id="expenseAmount" inputmode="decimal" required></div><div class="field"><label>Vencimento</label><input id="expenseDue" type="date" value="${isoDate(new Date())}"></div><div class="field"><label>Situação</label><select id="expenseStatus"><option value="predicted">Prevista</option><option value="paid">Paga</option></select></div><div class="field"><label>Forma de pagamento</label><select id="expenseMethod"><option value="pix">Pix</option><option value="cash">Dinheiro</option><option value="debit">Débito</option><option value="credit">Crédito</option></select></div><label class="permission-item"><span>Dinheiro saiu do caixa físico</span><input id="expenseFromCash" type="checkbox"></label><div class="field"><label>Observação</label><textarea id="expenseNote"></textarea></div><button class="gold-btn" type="submit">Salvar despesa</button></form>`);$('#expenseUnit').value=financeUnitId||catalog.units?.[0]?.id||'';$('#expenseForm').onsubmit=async e=>{e.preventDefault();try{await rpc('barberium_staff_create_expense',{p_unit_id:$('#expenseUnit').value,p_category_id:$('#expenseCategory').value||null,p_description:$('#expenseDescription').value.trim(),p_amount_cents:moneyToCents($('#expenseAmount').value),p_due_date:$('#expenseDue').value,p_status:$('#expenseStatus').value,p_payment_method:$('#expenseMethod').value,p_paid_from_cash:$('#expenseFromCash').checked,p_note:$('#expenseNote').value.trim()||null});toast('Despesa registrada.');closeModal();loadExpenses()}catch(err){toast(friendlyError(err))}}}
async function openExpenseCategories(){await loadExpenseCategories();openModal('DESPESAS','Categorias',`<div id="categoryList">${expenseCategoriesCache.map(c=>`<div class="unit-breakdown-row"><span>${esc(c.name)}${c.is_active?'':' • inativa'}</span><button class="soft-btn small" data-cat-edit="${c.id}">Editar</button></div>`).join('')}</div><button id="newCategory" class="gold-btn finance-wide" type="button">+ Nova categoria</button>`);$$('[data-cat-edit]').forEach(b=>b.onclick=()=>openCategoryEdit(expenseCategoriesCache.find(x=>x.id===b.dataset.catEdit)));$('#newCategory').onclick=()=>openCategoryEdit(null)}
function openCategoryEdit(c){openModal('CATEGORIA',c?.name||'Nova categoria',`<form id="categoryForm" class="form-grid"><div class="field"><label>Nome</label><input id="categoryName" value="${esc(c?.name||'')}" required></div><label class="permission-item"><span>Ativa</span><input id="categoryActive" type="checkbox" ${c?.is_active===false?'':'checked'}></label><button class="gold-btn" type="submit">Salvar</button></form>`);$('#categoryForm').onsubmit=async e=>{e.preventDefault();try{await rpc('barberium_staff_save_expense_category',{p_id:c?.id||null,p_name:$('#categoryName').value.trim(),p_is_active:$('#categoryActive').checked});toast('Categoria salva.');await loadExpenseCategories();openExpenseCategories()}catch(err){toast(friendlyError(err))}}}

async function loadCommissions(){if(!isManager()){return loadMyCommissions()}$('#commissionSubtabs').classList.remove('hidden');if(commissionTab==='plans')return loadPlanCommissionList();$('#commissionContent').innerHTML='<div class="loading">Carregando comissões…</div>';try{const d=await rpc('barberium_staff_commission_config');$('#commissionContent').innerHTML=(d.professionals||[]).map(p=>`<article class="plan-card"><div class="plan-head"><div><span class="plan-tag">${esc(p.settlement_cycle)}</span><h3>${esc(p.name)}</h3><p>${Number(p.default_percent||0).toLocaleString('pt-BR')}% padrão • base ${p.basis==='net'?'líquida':'bruta'}</p></div><button class="soft-btn" data-commission-pro="${p.id}" type="button">Configurar</button></div></article>`).join('')||'<div class="empty">Nenhum profissional.</div>';$$('[data-commission-pro]').forEach(b=>b.onclick=()=>openCommissionConfig((d.professionals||[]).find(x=>x.id===b.dataset.commissionPro)))}catch(e){$('#commissionContent').innerHTML=`<div class="empty">${esc(friendlyError(e))}</div>`}}
async function loadMyCommissions(){$('#commissionSubtabs').classList.add('hidden');$('#commissionContent').innerHTML='<div class="loading">Carregando suas comissões…</div>';try{const d=await rpc('barberium_staff_my_commissions',{});$('#commissionContent').innerHTML=`<div class="finance-summary"><article class="finance-kpi gold"><small>Saldo em aberto</small><strong>${moneyCents(d.open_cents)}</strong></article></div><h3 class="section-mini-title">Lançamentos</h3>${(d.entries||[]).map(e=>`<article class="service-stat"><div><h3>${esc(e.description||'Comissão')}</h3><p>${dateTimeBR(e.created_at)} • ${financeStatusLabel(e.status)}</p></div><strong>${moneyCents(e.amount_cents)}</strong></article>`).join('')||'<div class="empty">Nenhuma comissão no período.</div>'}<h3 class="section-mini-title">Acertos</h3>${(d.settlements||[]).map(x=>`<article class="service-stat"><div><h3>${brDateOnly(x.period_start)} — ${brDateOnly(x.period_end)}</h3><p>${financeStatusLabel(x.status)} • pago ${moneyCents(x.paid_cents)}</p></div><strong>${moneyCents(x.total_cents)}</strong></article>`).join('')||'<div class="empty">Nenhum acerto registrado.</div>'}`}catch(e){$('#commissionContent').innerHTML=`<div class="empty">${esc(friendlyError(e))}</div>`}}
function openCommissionConfig(p){openModal('COMISSÕES',p.name,`<form id="commissionConfigForm" class="form-grid"><div class="field"><label>Percentual padrão</label><input id="commissionDefault" inputmode="decimal" value="${String(p.default_percent||0).replace('.',',')}"></div><div class="field"><label>Ciclo de acerto</label><select id="commissionCycle"><option value="weekly" ${p.settlement_cycle==='weekly'?'selected':''}>Semanal</option><option value="biweekly" ${p.settlement_cycle==='biweekly'?'selected':''}>Quinzenal</option><option value="monthly" ${p.settlement_cycle==='monthly'?'selected':''}>Mensal</option></select></div><div class="field"><label>Base</label><select id="commissionBasis"><option value="gross" ${p.basis!=='net'?'selected':''}>Bruto pago</option><option value="net" ${p.basis==='net'?'selected':''}>Líquido após taxas</option></select></div><h3 class="section-mini-title">Por serviço</h3><div class="commission-services">${(p.services||[]).map(s=>`<div class="unit-breakdown-row"><span>${esc(s.service)}</span><span><select data-service-mode="${s.service_id}"><option value="percent" ${s.mode!=='none'?'selected':''}>Percentual</option><option value="none" ${s.mode==='none'?'selected':''}>Sem comissão</option></select> <input data-service-percent="${s.service_id}" inputmode="decimal" style="width:76px" value="${s.percent??''}" placeholder="%"></span></div>`).join('')}</div><button class="gold-btn" type="submit">Salvar comissão</button></form>`);$('#commissionConfigForm').onsubmit=async e=>{e.preventDefault();const rules=(p.services||[]).map(x=>({service_id:x.service_id,mode:$(`[data-service-mode="${x.service_id}"]`).value,percent:$(`[data-service-percent="${x.service_id}"]`).value?Number($(`[data-service-percent="${x.service_id}"]`).value.replace(',','.')):null}));try{await rpc('barberium_staff_save_commission_config',{p_professional_id:p.id,p_default_percent:Number($('#commissionDefault').value.replace(',','.'))||0,p_settlement_cycle:$('#commissionCycle').value,p_basis:$('#commissionBasis').value,p_service_rules:rules});toast('Comissões atualizadas.');closeModal();loadCommissions()}catch(err){toast(friendlyError(err))}}}
async function loadPlanCommissionList(){await loadMembershipPlans(false);$('#commissionContent').innerHTML=membershipPlansCache.length?membershipPlansCache.map(p=>{const c=p.rules?.commission||{type:'none'};return `<article class="plan-card"><div class="plan-head"><div><span class="plan-tag">${p.plan_type==='subscription'?'Assinatura':'Pacote'}</span><h3>${esc(p.name)}</h3><p>Comissão: ${esc(({none:'Sem comissão',hour:'Por hora',tickets:'Por fichas',attendance:'Por atendimento',sale:'Por venda'})[c.type]||c.type)}</p></div><button class="soft-btn" data-plan-commission="${p.id}" type="button">Configurar</button></div></article>`}).join(''):'<div class="empty">Crie um plano primeiro.</div>';$$('[data-plan-commission]').forEach(b=>b.onclick=()=>openPlanEditor(membershipPlansCache.find(x=>x.id===b.dataset.planCommission)))}

async function loadMembershipPlans(render=true){
  if(!isManager())return;
  try{
    membershipPlansCache=await rpc('barberium_staff_membership_plans');
    if(!render)return;
    if(!membershipPlansCache.length){$('#membershipPlanList').innerHTML='<div class="empty">Nenhuma assinatura ou pacote criado.</div>';return}
    $('#membershipPlanList').innerHTML=membershipPlansCache.map(p=>`<article class="plan-card"><div class="plan-head"><div><span class="plan-tag">${p.plan_type==='subscription'?'ASSINATURA':'PACOTE'}</span><h3>${esc(p.name)}</h3><p>${moneyCents(p.price_cents)} • v${p.version_no} • ${p.active_clients} cliente${p.active_clients===1?'':'s'}</p></div><button class="soft-btn" data-edit-plan="${p.id}" type="button">Editar</button></div><div class="plan-benefits">${(p.benefits||[]).map(b=>`<span>${esc(b.service)}: ${b.unlimited?'Ilimitado':p.plan_type==='subscription'?`${b.quantity} uso${b.quantity===1?'':'s'}/ciclo`:`${b.quantity} crédito${b.quantity===1?'':'s'}`}</span>`).join('')}</div><div class="plan-meta"><span>${p.public_visible?'Visível no site':'Interno'}</span><span>${p.is_active?'Ativo':'Inativo'}</span><span>Aquisição: ${esc(p.acquisition_mode)}</span></div></article>`).join('');
    $$('[data-edit-plan]').forEach(b=>b.onclick=()=>openPlanEditor(membershipPlansCache.find(x=>x.id===b.dataset.editPlan)));
  }catch(e){if(render)$('#membershipPlanList').innerHTML=`<div class="empty">${esc(friendlyError(e))}</div>`}
}

function planRule(p,k,def=''){const v=p?.rules?.[k];return v===undefined||v===null?def:v}
function commissionRuleFields(c,benefits){const type=c?.type||'none';const serviceRows=(benefits||[]).map(b=>`<div class="unit-breakdown-row"><span>${esc(b.service||serviceById(b.service_id)?.name||'Serviço')}</span><input data-plan-commission-service="${b.service_id}" inputmode="decimal" value="${c?.service_amounts?.[b.service_id]!=null?c.service_amounts[b.service_id]/100:c?.service_points?.[b.service_id]??''}" placeholder="${type==='attendance'?'R$':'fichas'}"></div>`).join('');return `<div class="field"><label>Tipo de comissão</label><select id="planCommissionType"><option value="none" ${type==='none'?'selected':''}>Sem comissão</option><option value="hour" ${type==='hour'?'selected':''}>Comissão por hora</option><option value="tickets" ${type==='tickets'?'selected':''}>Comissão por fichas</option><option value="attendance" ${type==='attendance'?'selected':''}>Comissão por atendimento</option><option value="sale" ${type==='sale'?'selected':''}>Comissão por venda</option></select></div><div id="planCommissionDetails">${type==='hour'?`<div class="field"><label>Valor por hora</label><input id="planHourlyRate" inputmode="decimal" value="${c.hourly_rate_cents?c.hourly_rate_cents/100:''}"></div>`:''}${type==='tickets'?`<div class="field"><label>% do valor do plano destinado à comissão</label><input id="planPoolPercent" inputmode="decimal" value="${c.pool_percent??''}"></div>${serviceRows}`:''}${type==='attendance'?serviceRows:''}${type==='sale'?`<div class="field"><label>% da venda para comissão</label><input id="planSalePercent" inputmode="decimal" value="${c.sale_percent??''}"></div><label class="permission-item"><span>Vendas feitas pela equipe podem gerar comissão</span><input id="planTeamSaleCommission" type="checkbox" ${c.team_sale_enabled?'checked':''}></label><small class="field-help">Solicitações feitas pelo próprio cliente no site não geram comissão de venda.</small>`:''}</div>`}
function bindPlanCommissionType(base={}){const sel=$('#planCommissionType');if(!sel)return;sel.onchange=()=>{const next={...base,type:sel.value};$('#planCommissionFields').innerHTML=commissionRuleFields(next,window.__planEditBenefits);bindPlanCommissionType(next)}}
function openPlanEditor(p=null){
  const benefits=p?.benefits?.length?p.benefits:[{service_id:catalog.services?.[0]?.id||'',quantity:1,unlimited:false,extra_discount_percent:0,min_days_between:null,max_per_week:null,max_per_month:null,rules:{}}];
  const c=p?.rules?.commission||{type:'none'};
  window.__planEditBenefits=JSON.parse(JSON.stringify(benefits));
  openModal('ASSINATURAS / PACOTES',p?`Editar ${p.name}`:'Novo plano',`<form id="planForm" class="form-grid">
    <div class="field"><label>Nome</label><input id="planName" value="${esc(p?.name||'')}" required></div>
    <div class="field"><label>Descrição</label><textarea id="planDescription">${esc(p?.description||'')}</textarea></div>
    <div class="field"><label>Tipo</label><select id="planType"><option value="subscription" ${p?.plan_type!=='package'?'selected':''}>Assinatura</option><option value="package" ${p?.plan_type==='package'?'selected':''}>Pacote</option></select></div>
    <div class="field"><label>Valor</label><input id="planPrice" inputmode="decimal" value="${centsInput(p?.price_cents||0)}"></div>
    <div class="field"><label>Como pode ser adquirido</label><select id="planAcquisition"><option value="team" ${p?.acquisition_mode==='team'?'selected':''}>Somente equipe/ADM</option><option value="site" ${p?.acquisition_mode==='site'?'selected':''}>Somente pelo site</option><option value="both" ${p?.acquisition_mode==='both'?'selected':''}>Pelos dois meios</option></select></div>
    <label class="permission-item"><span>Exibir publicamente</span><input id="planPublic" type="checkbox" ${p?.public_visible?'checked':''}></label>
    <label class="permission-item"><span>Plano ativo</span><input id="planActive" type="checkbox" ${p?.is_active===false?'':'checked'}></label>
    <div class="notice-box">O plano só é ativado depois do pagamento integral. Pagamento parcial não libera benefícios nem créditos.</div>
    <h3 class="section-mini-title">Benefícios</h3><div id="planBenefits"></div><button id="addPlanBenefit" class="soft-btn" type="button">+ Adicionar serviço</button>
    <h3 class="section-mini-title">Regras gerais</h3>
    <div class="rules-grid">
      <div class="field"><label>Em caso de falta</label><select id="planNoShow"><option value="keep" ${planRule(p,'no_show_rule','keep')==='keep'?'selected':''}>Mantém o benefício</option><option value="lose" ${planRule(p,'no_show_rule')==='lose'?'selected':''}>Conta como uso</option><option value="admin" ${planRule(p,'no_show_rule')==='admin'?'selected':''}>ADM decide</option></select></div>
      <div class="field"><label>Uso em combo</label><select id="planComboMode"><option value="full_retail" ${planRule(p,'combo_credit_mode','full_retail')==='full_retail'?'selected':''}>Abater valor avulso integral</option><option value="proportional" ${planRule(p,'combo_credit_mode')==='proportional'?'selected':''}>Rateio proporcional</option></select></div>
      <div class="field"><label>Unidades</label><select id="planUnitScope"><option value="all" ${planRule(p,'unit_scope','all')==='all'?'selected':''}>Todas as unidades</option><option value="selected" ${planRule(p,'unit_scope')==='selected'?'selected':''}>Unidades selecionadas</option><option value="origin" ${planRule(p,'unit_scope')==='origin'?'selected':''}>Somente unidade de origem</option></select></div>
    </div>
    <div id="planSelectedUnits" class="permission-list">${(catalog.units||[]).map(u=>`<label class="permission-item"><span>${esc(u.name)}</span><input data-plan-unit="${u.id}" type="checkbox" ${(p?.units||[]).includes(u.id)?'checked':''}></label>`).join('')}</div>
    <section data-plan-section="subscription">
      <h3 class="section-mini-title">Assinatura</h3>
      <div class="notice-box">Assinatura é por período. Os números dos benefícios abaixo são limites de uso no ciclo, não uma carteira de créditos acumulados.</div>
      <div class="rules-grid">
        <div class="field"><label>Ciclo</label><select id="planCycle"><option value="signup_date" ${['signup_date','anniversary'].includes(planRule(p,'cycle_mode','signup_date'))?'selected':''}>Data de adesão</option><option value="calendar_month" ${['calendar_month','calendar'].includes(planRule(p,'cycle_mode'))?'selected':''}>Mês-calendário</option><option value="fixed_day" ${planRule(p,'cycle_mode')==='fixed_day'?'selected':''}>Dia fixo escolhido pela barbearia</option></select></div>
        <div class="field"><label>Dia fixo do mês</label><input id="planFixedDay" type="number" min="1" max="31" value="${planRule(p,'fixed_day',1)}"></div>
        <div class="field"><label>Primeiro ciclo</label><select id="planFirstCycle"><option value="full" ${planRule(p,'first_cycle_mode','full')==='full'?'selected':''}>Integral</option><option value="proportional" ${planRule(p,'first_cycle_mode')==='proportional'?'selected':''}>Proporcional</option><option value="custom" ${planRule(p,'first_cycle_mode')==='custom'?'selected':''}>Personalizado pelo ADM</option><option value="next_cycle" ${planRule(p,'first_cycle_mode')==='next_cycle'?'selected':''}>Começa no próximo vencimento</option></select></div>
        <div class="field"><label>Valor do primeiro ciclo personalizado</label><input id="planFirstCustom" inputmode="decimal" value="${centsInput(planRule(p,'first_cycle_custom_amount_cents',0))}"></div>
        <div class="field"><label>Tolerância de atraso (dias)</label><input id="planGrace" type="number" min="0" value="${planRule(p,'grace_days',0)}"></div>
        <div class="field"><label>Após a tolerância, ao pagar</label><select id="planLateCycle"><option value="retroactive" ${planRule(p,'late_payment_cycle_mode','retroactive')==='retroactive'?'selected':''}>Mantém o ciclo na data original</option><option value="from_payment" ${planRule(p,'late_payment_cycle_mode')==='from_payment'?'selected':''}>Novo ciclo começa no pagamento</option></select></div>
        <div class="field"><label>Durante tolerância</label><select id="planGraceAccess"><option value="keep_active" ${planRule(p,'grace_access','keep_active')==='keep_active'?'selected':''}>Mantém benefícios ativos</option><option value="no_new_credits" ${planRule(p,'grace_access')==='no_new_credits'?'selected':''}>Bloqueia novos usos até pagar</option></select></div>
      </div>
      <h3 class="section-mini-title">Pausa e cancelamento</h3>
      <label class="permission-item"><span>Cliente pode solicitar pausa</span><input id="planAllowPause" type="checkbox" ${planRule(p,'allow_pause',true)!==false?'checked':''}></label>
      <div class="rules-grid"><div class="field"><label>Pausa mínima (dias)</label><input id="planPauseMin" type="number" min="1" value="${planRule(p,'pause_min_days','')}"></div><div class="field"><label>Pausa máxima (dias)</label><input id="planPauseMax" type="number" min="1" value="${planRule(p,'pause_max_days','')}"></div></div>
      <div class="notice-box">Ao aprovar a pausa, a vigência e os benefícios ficam congelados e a renovação é adiada pelo mesmo número de dias.</div>
      <label class="permission-item"><span>Cliente pode solicitar cancelamento</span><input id="planAllowCancel" type="checkbox" ${planRule(p,'allow_cancel',true)!==false?'checked':''}></label>
      <div class="notice-box">Cancelamento aprovado preserva o ciclo já pago e bloqueia a próxima renovação.</div><input id="planCancelMode" type="hidden" value="end_cycle">
    </section>
    <section data-plan-section="package">
      <h3 class="section-mini-title">Pacote</h3>
      <div class="rules-grid">
        <div class="field"><label>Validade dos créditos</label><select id="planValidity"><option value="fixed_days" ${planRule(p,'credit_validity','no_expiry')==='fixed_days'?'selected':''}>Validade fixa em dias</option><option value="no_expiry" ${planRule(p,'credit_validity','no_expiry')==='no_expiry'?'selected':''}>Sem validade</option></select></div>
        <div class="field"><label>Validade fixa (dias)</label><input id="planValidityDays" type="number" min="1" value="${planRule(p,'fixed_validity_days',90)}"></div>
      </div>
      <div class="field"><label>Cancelamento / reembolso</label><select id="planRefundMode"><option value="nonrefundable" ${planRule(p,'refund_mode','nonrefundable')==='nonrefundable'?'selected':''}>Não reembolsável</option><option value="proportional" ${planRule(p,'refund_mode')==='proportional'?'selected':''}>Reembolso proporcional ao saldo não usado</option><option value="manual" ${planRule(p,'refund_mode')==='manual'?'selected':''}>Valor definido pelo ADM</option><option value="no_after_use" ${planRule(p,'refund_mode')==='no_after_use'?'selected':''}>Sem cancelamento após o primeiro uso</option></select></div>
    </section>
    <h3 class="section-mini-title">Comissão deste plano</h3><div id="planCommissionFields">${commissionRuleFields(c,benefits)}</div>
    <button id="savePlanButton" class="gold-btn finance-wide" type="submit">${p?'Salvar nova versão':'Criar plano'}</button>
  </form>`);
  renderPlanBenefitEditor();
  $('#addPlanBenefit').onclick=()=>{window.__planEditBenefits.push({service_id:catalog.services?.[0]?.id||'',quantity:1,unlimited:false,extra_discount_percent:0,min_days_between:null,max_per_week:null,max_per_month:null,rules:{}});renderPlanBenefitEditor()};
  bindPlanCommissionType(p?.rules?.commission||{});
  $('#planType').onchange=()=>{syncPlanTypeEditor();renderPlanBenefitEditor()};
  $('#planCycle').onchange=syncPlanCycleEditor;$('#planFirstCycle').onchange=syncPlanCycleEditor;
  syncPlanTypeEditor();syncPlanCycleEditor();
  $('#planForm').onsubmit=e=>saveMembershipPlan(e,p);
}
function syncPlanTypeEditor(){
  const type=$('#planType')?.value||'subscription';
  $$('[data-plan-section]').forEach(x=>x.classList.toggle('hidden',x.dataset.planSection!==type));
}
function syncPlanCycleEditor(){if(!$('#planCycle'))return;$('#planFixedDay').disabled=$('#planCycle').value!=='fixed_day';$('#planFirstCustom').disabled=$('#planFirstCycle').value!=='custom'}

function renderPlanBenefitEditor(){
  const root=$('#planBenefits');if(!root)return;
  const subscription=$('#planType')?.value!=='package';
  root.innerHTML=window.__planEditBenefits.map((b,i)=>`<div class="benefit-editor" data-benefit-index="${i}"><div class="field"><label>Serviço</label><select data-ben-service>${(catalog.services||[]).map(s=>`<option value="${s.id}" ${s.id===b.service_id?'selected':''}>${esc(s.name)}</option>`).join('')}</select></div><label class="permission-item"><span>${subscription?'Uso ilimitado no ciclo':'Créditos ilimitados'}</span><input data-ben-unlimited type="checkbox" ${b.unlimited?'checked':''}></label><div class="field"><label>${subscription?'Limite de usos no ciclo':'Créditos / sessões'}</label><input data-ben-qty type="number" min="1" value="${b.quantity||1}" ${b.unlimited?'disabled':''}></div><div class="field"><label>Desconto em extras %</label><input data-ben-discount inputmode="decimal" value="${b.extra_discount_percent||0}"></div><div class="field"><label>Intervalo mínimo (dias)</label><input data-ben-min-days type="number" min="0" value="${b.min_days_between??''}"></div><div class="field"><label>Máx. por semana</label><input data-ben-week type="number" min="1" value="${b.max_per_week??''}"></div><div class="field"><label>Máx. por mês</label><input data-ben-month type="number" min="1" value="${b.max_per_month??''}"></div>${window.__planEditBenefits.length>1?'<button data-remove-benefit class="danger-btn small" type="button">Remover</button>':''}</div>`).join('');
  $$('[data-benefit-index]',root).forEach(box=>{const i=Number(box.dataset.benefitIndex);$('[data-ben-unlimited]',box).onchange=e=>{$('[data-ben-qty]',box).disabled=e.target.checked};$('[data-remove-benefit]',box)?.addEventListener('click',()=>{window.__planEditBenefits.splice(i,1);renderPlanBenefitEditor()})});
}

async function saveMembershipPlan(e,p){
  e.preventDefault();
  const type=$('#planType').value;
  const benefits=$$('[data-benefit-index]').map((box,i)=>({service_id:$('[data-ben-service]',box).value,unlimited:$('[data-ben-unlimited]',box).checked,quantity:Number($('[data-ben-qty]',box).value||1),extra_discount_percent:Number($('[data-ben-discount]',box).value.replace(',','.'))||0,min_days_between:$('[data-ben-min-days]',box).value?Number($('[data-ben-min-days]',box).value):null,max_per_week:$('[data-ben-week]',box).value?Number($('[data-ben-week]',box).value):null,max_per_month:$('[data-ben-month]',box).value?Number($('[data-ben-month]',box).value):null,rules:{},sort_order:i}));
  const ctype=$('#planCommissionType').value;const commission={type:ctype};
  if(ctype==='hour')commission.hourly_rate_cents=moneyToCents($('#planHourlyRate')?.value||0);
  if(ctype==='tickets'){commission.pool_percent=Number($('#planPoolPercent')?.value?.replace(',','.')||0);commission.service_points={};$$('[data-plan-commission-service]').forEach(x=>commission.service_points[x.dataset.planCommissionService]=Number(x.value.replace(',','.'))||0)}
  if(ctype==='attendance'){commission.service_amounts={};$$('[data-plan-commission-service]').forEach(x=>commission.service_amounts[x.dataset.planCommissionService]=moneyToCents(x.value))}
  if(ctype==='sale'){commission.sale_percent=Number($('#planSalePercent')?.value?.replace(',','.')||0);commission.team_sale_enabled=$('#planTeamSaleCommission')?.checked||false;commission.site_sale_enabled=false}
  const rules={
    no_show_rule:$('#planNoShow').value,combo_credit_mode:$('#planComboMode').value,unit_scope:$('#planUnitScope').value,
    benefit_model:type==='subscription'?'period':'credits',allow_manual_extension:true,credit_valid_on_appointment_date:true,commission
  };
  if(type==='subscription')Object.assign(rules,{
    cycle_mode:$('#planCycle').value,fixed_day:$('#planCycle').value==='fixed_day'?Number($('#planFixedDay').value||1):null,first_cycle_mode:$('#planFirstCycle').value,first_cycle_custom_amount_cents:$('#planFirstCycle').value==='custom'?moneyToCents($('#planFirstCustom').value):null,grace_days:Number($('#planGrace').value||0),late_payment_cycle_mode:$('#planLateCycle').value,grace_access:$('#planGraceAccess').value,
    allow_pause:$('#planAllowPause').checked,pause_min_days:$('#planPauseMin').value?Number($('#planPauseMin').value):null,pause_max_days:$('#planPauseMax').value?Number($('#planPauseMax').value):null,pause_validity:'freeze',
    allow_cancel:$('#planAllowCancel').checked,cancel_mode:$('#planCancelMode').value
  });
  else Object.assign(rules,{
    credit_validity:$('#planValidity').value,fixed_validity_days:Number($('#planValidityDays').value||90),refund_mode:$('#planRefundMode').value,credits_personal:true
  });
  if(type==='subscription'&&rules.pause_min_days&&rules.pause_max_days&&rules.pause_min_days>rules.pause_max_days){toast('A pausa mínima não pode ser maior que a máxima.');return}
  const btn=$('#savePlanButton');btn.disabled=true;
  try{await rpc('barberium_staff_save_membership_plan',{p_plan_id:p?.id||null,p_name:$('#planName').value.trim(),p_description:$('#planDescription').value.trim()||null,p_plan_type:type,p_price_cents:moneyToCents($('#planPrice').value),p_acquisition_mode:$('#planAcquisition').value,p_public_visible:$('#planPublic').checked,p_is_active:$('#planActive').checked,p_rules:rules,p_benefits:benefits,p_unit_ids:$$('[data-plan-unit]:checked').map(x=>x.dataset.planUnit)});toast(p?'Nova versão do plano salva.':'Plano criado.');closeModal();await loadMembershipPlans();if(currentFinanceTab==='commissions'&&commissionTab==='plans')loadPlanCommissionList()}catch(err){toast(friendlyError(err));btn.disabled=false}
}

async function openMembershipRequests(){
  openModal('PLANOS','Solicitações','<div class="loading">Carregando…</div>');
  try{
    const [purchase,actions]=await Promise.all([rpc('barberium_staff_membership_requests'),rpc('barberium_staff_membership_action_requests')]);
    const purchaseHtml=(purchase||[]).length?(purchase||[]).map(r=>`<article class="plan-card"><div class="plan-head"><div><span class="plan-tag">${r.plan_type==='subscription'?'Assinatura':'Pacote'}</span><h3>${esc(r.customer)}</h3><p>${esc(r.plan)} • ${dateTimeBR(r.created_at)}</p></div></div><div class="action-row"><button class="gold-btn" data-approve-request="${r.id}" type="button">Aprovar adesão</button><button class="danger-btn" data-reject-request="${r.id}" type="button">Recusar</button></div></article>`).join(''):'<div class="empty">Nenhuma adesão pendente.</div>';
    const actionHtml=(actions||[]).length?(actions||[]).map(r=>`<article class="plan-card"><div class="plan-head"><div><span class="plan-tag">${r.action_type==='pause'?'PAUSA':'CANCELAMENTO'}</span><h3>${esc(r.customer)}</h3><p>${esc(r.plan)}${r.action_type==='pause'?` • ${r.requested_days} dia${r.requested_days===1?'':'s'}`:''} • ${dateTimeBR(r.created_at)}</p>${r.customer_note?`<p>${esc(r.customer_note)}</p>`:''}</div></div><div class="action-row"><button class="gold-btn" data-approve-action="${r.id}" type="button">Aprovar</button><button class="danger-btn" data-reject-action="${r.id}" type="button">Recusar</button></div></article>`).join(''):'<div class="empty">Nenhuma pausa ou cancelamento pendente.</div>';
    $('#modalBody').innerHTML=`<h3 class="section-mini-title">Adesões pelo site</h3>${purchaseHtml}<h3 class="section-mini-title">Pausa / cancelamento</h3>${actionHtml}`;
    $$('[data-approve-request]').forEach(b=>b.onclick=()=>openApproveRequest((purchase||[]).find(x=>x.id===b.dataset.approveRequest)));
    $$('[data-reject-request]').forEach(b=>b.onclick=async()=>{try{await rpc('barberium_staff_decide_membership_request',{p_request_id:b.dataset.rejectRequest,p_approve:false,p_unit_id:catalog.units?.[0]?.id,p_mark_paid:false,p_payment_method:'pix'});toast('Solicitação recusada.');openMembershipRequests()}catch(e){toast(friendlyError(e))}});
    $$('[data-approve-action]').forEach(b=>b.onclick=()=>decideMembershipActionRequest(b.dataset.approveAction,true));
    $$('[data-reject-action]').forEach(b=>b.onclick=()=>decideMembershipActionRequest(b.dataset.rejectAction,false));
  }catch(e){$('#modalBody').innerHTML=`<div class="empty">${esc(friendlyError(e))}</div>`}
}
async function decideMembershipActionRequest(id,approve){
  const note=prompt(approve?'Observação da aprovação (opcional):':'Motivo/observação da recusa (opcional):')||'';
  try{await rpc('barberium_staff_decide_membership_action_request',{p_request_id:id,p_approve:approve,p_decision_note:note||null});toast(approve?'Solicitação aprovada.':'Solicitação recusada.');openMembershipRequests()}catch(e){toast(friendlyError(e))}
}

function openApproveRequest(r){openModal('ATIVAR PLANO',`${r.customer} • ${r.plan}`,`<form id="approveRequestForm" class="form-grid"><div class="field"><label>Unidade de origem</label><select id="requestUnit">${financeUnitOptions(false)}</select></div><label class="permission-item"><span>Pagamento integral já recebido</span><input id="requestPaid" type="checkbox"></label><div class="field"><label>Forma de pagamento</label><select id="requestMethod"><option value="pix">Pix</option><option value="cash">Dinheiro</option><option value="debit">Débito</option><option value="credit">Crédito</option></select></div><button class="gold-btn" type="submit">Aprovar solicitação</button></form>`);$('#requestUnit').value=catalog.units?.[0]?.id||'';$('#approveRequestForm').onsubmit=async e=>{e.preventDefault();try{await rpc('barberium_staff_decide_membership_request',{p_request_id:r.id,p_approve:true,p_unit_id:$('#requestUnit').value,p_mark_paid:$('#requestPaid').checked,p_payment_method:$('#requestMethod').value});toast($('#requestPaid').checked?'Pagamento integral confirmado e plano ativado.':'Solicitação aprovada. Plano aguardando pagamento integral.');closeModal();loadMembershipPlans()}catch(err){toast(friendlyError(err))}}}

async function loadClientMemberships(customerId){
  const root=$('#clientMemberships');if(!root)return;root.innerHTML='<div class="loading">Carregando planos…</div>';
  try{
    const [rows,states]=await Promise.all([rpc('barberium_staff_customer_memberships',{p_customer_id:customerId}),rpc('barberium_staff_membership_actions_state',{p_customer_id:customerId})]);
    const stateMap=Object.fromEntries((states||[]).map(x=>[x.membership_id,x]));
    rows.forEach(m=>Object.assign(m,stateMap[m.id]||{}));
    root.innerHTML=rows.length?rows.map(m=>membershipAdminCard(m)).join(''):'<div class="empty">Cliente sem assinatura ou pacote.</div>';
    $$('[data-membership-pay]').forEach(b=>b.onclick=()=>openMembershipPayment(rows.find(x=>x.id===b.dataset.membershipPay)));
    $$('[data-package-adjust]').forEach(b=>b.onclick=()=>openPackageCreditAdjustment(rows.find(x=>x.id===b.dataset.packageAdjust)));
    $$('[data-package-cancel]').forEach(b=>b.onclick=()=>openPackageCancellation(rows.find(x=>x.id===b.dataset.packageCancel),customerId));
  }catch(e){root.innerHTML=`<div class="empty">${esc(friendlyError(e))}</div>`}
}
function membershipAdminCard(m){
  const pendingPay=m.plan_type==='package'?m.status==='pending':(m.cycles||[]).some(c=>['pending','overdue'].includes(c.status));
  const allocation=(m.credits||[]).map(c=>m.plan_type==='subscription'?`<div><small>${esc(c.service)}</small><strong>${c.unlimited?'Ilimitado no ciclo':`${c.available} uso${c.available===1?'':'s'} restante${c.available===1?'':'s'}`}</strong><span>${c.used} realizado${c.used===1?'':'s'} • ${c.reserved} reservado${c.reserved===1?'':'s'}</span></div>`:`<div><small>${esc(c.service)}</small><strong>${c.unlimited?'Ilimitado':`${c.available} crédito${c.available===1?'':'s'} disponível${c.available===1?'':'is'}`}</strong><span>${c.used} usado${c.used===1?'':'s'} • ${c.reserved} reservado${c.reserved===1?'':'s'}${c.expires_on?` • vence ${brDateOnly(c.expires_on)}`:''}</span></div>`).join('');
  const state=m.plan_type==='subscription'?`${m.paused_until?`<span>Pausada até ${brDateOnly(m.paused_until)}</span>`:''}${m.renewal_blocked?`<span>Cancelamento programado${m.cancel_effective_on?` para ${brDateOnly(m.cancel_effective_on)}`:''}</span>`:''}`:'';
  return `<article class="membership-client-card"><div class="plan-head"><div><span class="plan-tag">${m.plan_type==='subscription'?'Assinatura':'Pacote'} • ${financeStatusLabel(m.status)}</span><h3>${esc(m.name)}</h3><p>${moneyCents(m.price_cents)}${m.started_at?` • desde ${dateTimeBR(m.started_at)}`:''}</p></div></div>${state?`<div class="plan-meta">${state}</div>`:''}<div class="credit-grid">${allocation||`<div><small>${m.plan_type==='subscription'?'Benefícios':'Créditos'}</small><strong>Aguardando pagamento integral</strong></div>`}</div><div class="action-row">${pendingPay?`<button class="gold-btn" data-membership-pay="${m.id}" type="button">Confirmar pagamento integral</button>`:''}${m.plan_type==='package'&&m.status==='active'?`<button class="soft-btn" data-package-adjust="${m.id}" type="button">Ajustar créditos</button><button class="danger-btn" data-package-cancel="${m.id}" type="button">Cancelar pacote</button>`:''}</div></article>`;
}
function openPackageCreditAdjustment(m){
  const finite=(m.credits||[]).filter(c=>!c.unlimited);
  if(!finite.length){toast('Este pacote não possui créditos finitos para ajustar.');return}
  openModal('PACOTE',`Ajustar créditos • ${m.name}`,`<form id="packageCreditForm" class="form-grid"><div class="field"><label>Benefício</label><select id="packageCreditBucket">${finite.map(c=>`<option value="${c.bucket_id}">${esc(c.service)} • ${c.available} disponíveis</option>`).join('')}</select></div><div class="field"><label>Ajuste</label><input id="packageCreditDelta" type="number" step="1" placeholder="Ex.: 1 ou -1" required></div><div class="field"><label>Motivo obrigatório</label><textarea id="packageCreditReason" required></textarea></div><button class="gold-btn" type="submit">Registrar ajuste</button></form>`);
  $('#packageCreditForm').onsubmit=async e=>{e.preventDefault();const delta=Number($('#packageCreditDelta').value);if(!Number.isInteger(delta)||delta===0){toast('Informe uma quantidade inteira diferente de zero.');return}try{await rpc('barberium_staff_adjust_package_credit',{p_membership_id:m.id,p_bucket_id:$('#packageCreditBucket').value,p_delta:delta,p_reason:$('#packageCreditReason').value.trim()});toast('Créditos ajustados e registrados no histórico.');closeModal();loadClientMemberships(m.customer_id||window.__currentClientId)}catch(err){toast(friendlyError(err))}};
}
function openPackageCancellation(m,customerId){
  const policy=m.rules?.refund_mode||'nonrefundable';
  const labels={nonrefundable:'Sem reembolso',proportional:'Reembolso proporcional ao saldo não usado',manual:'Reembolso definido pelo ADM',no_after_use:'Cancelamento somente antes do primeiro uso'};
  openModal('CANCELAR PACOTE',m.name,`<div class="notice-box">Política deste pacote: <strong>${esc(labels[policy]||policy)}</strong>.</div><form id="packageCancelForm" class="form-grid"><div class="field"><label>Motivo obrigatório</label><textarea id="packageCancelReason" required></textarea></div>${policy==='manual'?'<div class="field"><label>Valor do reembolso</label><input id="packageManualRefund" inputmode="decimal" value="0,00"></div>':''}<button class="danger-btn" type="submit">Confirmar cancelamento</button></form>`);
  $('#packageCancelForm').onsubmit=async e=>{e.preventDefault();if(!confirm('Confirmar o cancelamento deste pacote?'))return;try{const r=await rpc('barberium_staff_cancel_package',{p_membership_id:m.id,p_reason:$('#packageCancelReason').value.trim(),p_manual_refund_cents:policy==='manual'?moneyToCents($('#packageManualRefund').value):null});toast(r.refund_cents>0?`Pacote cancelado. Reembolso: ${moneyCents(r.refund_cents)}`:'Pacote cancelado.');closeModal();loadClientMemberships(customerId);loadFinanceOverview()}catch(err){toast(friendlyError(err))}};
}

async function openAssignMembership(customerId){await loadMembershipPlans(false);const active=membershipPlansCache.filter(p=>p.is_active&&['team','both'].includes(p.acquisition_mode));if(!active.length){toast('Crie um plano disponível para a equipe primeiro.');return}openModal('CLIENTE','Adicionar assinatura/pacote',`<form id="assignMembershipForm" class="form-grid"><div class="field"><label>Plano</label><select id="assignPlan">${active.map(p=>`<option value="${p.id}">${esc(p.name)} • ${moneyCents(p.price_cents)}</option>`).join('')}</select></div><div class="field"><label>Unidade de origem</label><select id="assignUnit">${financeUnitOptions(false)}</select></div><div class="field"><label>Início</label><input id="assignStart" type="date" value="${isoDate(new Date())}"></div><label class="permission-item"><span>Pagamento integral já recebido</span><input id="assignPaid" type="checkbox"></label><div class="field"><label>Forma de pagamento</label><select id="assignMethod"><option value="pix">Pix</option><option value="cash">Dinheiro</option><option value="debit">Débito</option><option value="credit">Crédito</option></select></div><button class="gold-btn" type="submit">Adicionar ao cliente</button></form>`);$('#assignUnit').value=catalog.units?.[0]?.id||'';$('#assignMembershipForm').onsubmit=async e=>{e.preventDefault();try{await rpc('barberium_staff_assign_membership',{p_customer_id:customerId,p_plan_id:$('#assignPlan').value,p_unit_id:$('#assignUnit').value,p_start_date:$('#assignStart').value,p_mark_paid:$('#assignPaid').checked,p_payment_method:$('#assignMethod').value});toast($('#assignPaid').checked?'Pagamento integral confirmado e plano ativado.':'Plano adicionado. Aguardando pagamento integral.');closeModal();openClientDetail(customerId)}catch(err){toast(friendlyError(err))}}}
function openMembershipPayment(m){
  const cycle=(m.cycles||[]).find(c=>['pending','overdue'].includes(c.status));
  openModal('PAGAMENTO INTEGRAL',m.name,`<div class="detail-grid"><div class="detail-box wide"><small>Valor integral</small><strong>${moneyCents(cycle?.amount_cents||m.price_cents)}</strong></div>${cycle?`<div class="detail-box"><small>Vencimento</small><strong>${brDateOnly(cycle.due_date)}</strong></div><div class="detail-box"><small>Status</small><strong>${financeStatusLabel(cycle.status)}</strong></div>`:''}</div><div class="notice-box">O plano só será ativado após a confirmação deste pagamento integral.</div><form id="membershipPaymentForm" class="form-grid"><div class="field"><label>Forma de pagamento</label><select id="membershipPaymentMethod"><option value="pix">Pix</option><option value="cash">Dinheiro</option><option value="debit">Débito</option><option value="credit">Crédito</option></select></div><button class="gold-btn" type="submit">Confirmar pagamento integral</button></form>`);
  $('#membershipPaymentForm').onsubmit=async e=>{e.preventDefault();try{await rpc('barberium_staff_record_membership_payment',{p_membership_id:m.id,p_cycle_id:cycle?.id||null,p_method:$('#membershipPaymentMethod').value});toast(m.plan_type==='subscription'?'Pagamento confirmado. Benefícios da assinatura liberados.':'Pagamento confirmado. Créditos do pacote liberados.');closeModal();if(window.__currentClientId)loadClientMemberships(window.__currentClientId);loadFinanceOverview()}catch(err){toast(friendlyError(err))}};
}


function switchPanel(panel){currentPanel=panel;$('#agendaPanel').classList.toggle('hidden',panel!=='agenda');$('#performancePanel').classList.toggle('hidden',panel!=='performance');$('#clientsPanel').classList.toggle('hidden',panel!=='clients');$('#financePanel').classList.toggle('hidden',panel!=='finance');$('#teamPanel').classList.toggle('hidden',panel!=='team');$('#settingsPanel')?.classList.toggle('hidden',panel!=='settings');$$('[data-team-panel]').forEach(b=>b.classList.toggle('active',b.dataset.teamPanel===panel));if(panel==='performance')loadPerformance();if(panel==='clients'){currentClientTab='base';$$('[data-client-tab]').forEach(x=>x.classList.toggle('active',x.dataset.clientTab==='base'));$('#clientBaseTab').classList.remove('hidden');$('#clientReportsTab').classList.add('hidden');$('#clientCampaignsTab').classList.add('hidden');loadClients()}if(panel==='finance')loadFinance();if(panel==='team')loadTeam();if(panel==='settings')window.BarberiumSettings?.load();window.scrollTo({top:0,behavior:'smooth'})}

$('#loginForm').addEventListener('submit',async e=>{e.preventDefault();const btn=$('#loginButton');btn.disabled=true;btn.textContent='Entrando…';$('#loginError').textContent='';try{await login($('#email').value.trim(),$('#password').value);await showDashboard()}catch(err){$('#loginError').textContent=err.message}finally{btn.disabled=false;btn.textContent='Entrar'}});
$('#togglePassword').onclick=()=>{const p=$('#password');p.type=p.type==='password'?'text':'password';$('#togglePassword').textContent=p.type==='password'?'Ver':'Ocultar'};
$('#logoutButton').onclick=logout;$('#prevDay').onclick=()=>moveDate(-1);$('#nextDay').onclick=()=>moveDate(1);$('#todayButton').onclick=()=>{currentDate=isoDate(new Date());renderDate();loadAgenda()};$('#dateButton').onclick=()=>{if($('#dateInput').showPicker)$('#dateInput').showPicker();else $('#dateInput').click()};$('#dateInput').onchange=()=>{if($('#dateInput').value){currentDate=$('#dateInput').value;renderDate();loadAgenda()}};
$('#newAppointmentButton').onclick=()=>openBookingModal('create');$('#newBlockButton').onclick=()=>openBlockModal('create');$('#modalClose').onclick=closeModal;$('#modalBackdrop').addEventListener('click',e=>{if(e.target===$('#modalBackdrop'))closeModal()});
$$('[data-team-panel]').forEach(b=>b.onclick=()=>switchPanel(b.dataset.teamPanel));$$('[data-period]').forEach(b=>b.onclick=()=>{activePeriod=b.dataset.period;$$('[data-period]').forEach(x=>x.classList.toggle('active',x===b));loadPerformance()});


$$('[data-client-tab]').forEach(b=>b.onclick=()=>switchClientTab(b.dataset.clientTab));
$$('[data-client-base-filter]').forEach(b=>b.onclick=()=>{clientBaseFilter=b.dataset.clientBaseFilter;$$('[data-client-base-filter]').forEach(x=>x.classList.toggle('active',x===b));loadClients()});
let clientSearchTimer=null;$('#clientSearch')?.addEventListener('input',()=>{clearTimeout(clientSearchTimer);clientSearchTimer=setTimeout(loadClients,280)});
$$('[data-birthday-period]').forEach(b=>b.onclick=()=>{birthdayPeriod=b.dataset.birthdayPeriod;$$('[data-birthday-period]').forEach(x=>x.classList.toggle('active',x===b));renderBirthdays()});
$('#importClientsButton')?.addEventListener('click',openImportClients);$('#exportClientsButton')?.addEventListener('click',openExportClients);
$('#loadCampaignAudience')?.addEventListener('click',loadCampaignAudience);$('#previewCampaign')?.addEventListener('click',previewCampaign);$('#saveCampaignTemplate')?.addEventListener('click',saveCampaignTemplate);$('#sendCampaignNow')?.addEventListener('click',()=>createCampaign(false));$('#scheduleCampaign')?.addEventListener('click',()=>createCampaign(true));
$('#campaignTemplate')?.addEventListener('change',e=>{const t=campaignTemplatesCache.find(x=>x.id===e.target.value);if(t)$('#campaignMessage').value=t.message});


$$('[data-finance-tab]').forEach(b=>b.onclick=()=>switchFinanceTab(b.dataset.financeTab));
$('#financeUnit')?.addEventListener('change',e=>{financeUnitId=e.target.value;if(currentFinanceTab==='overview')loadFinanceOverview();if(currentFinanceTab==='cash')loadCashStatus();if(currentFinanceTab==='expenses')loadExpenses()});
$('#financeMonth')?.addEventListener('change',e=>{financeMonth=e.target.value||financeMonth;if(currentFinanceTab==='overview')loadFinanceOverview();if(currentFinanceTab==='expenses')loadExpenses()});
$('#financeBasis')?.addEventListener('change',e=>{financeBasis=e.target.value;e.target.dataset.userChanged='1';loadFinanceOverview()});
$('#financeSettingsButton')?.addEventListener('click',openFinanceSettings);$('#newExpenseButton')?.addEventListener('click',openNewExpense);$('#expenseCategoriesButton')?.addEventListener('click',openExpenseCategories);$('#newPlanButton')?.addEventListener('click',()=>openPlanEditor(null));$('#planRequestsButton')?.addEventListener('click',openMembershipRequests);
$$('[data-expense-filter]').forEach(b=>b.onclick=()=>{expenseStatusFilter=b.dataset.expenseFilter;$$('[data-expense-filter]').forEach(x=>x.classList.toggle('active',x===b));loadExpenses()});
$$('[data-commission-tab]').forEach(b=>b.onclick=()=>{commissionTab=b.dataset.commissionTab;$$('[data-commission-tab]').forEach(x=>x.classList.toggle('active',x===b));loadCommissions()});

(async()=>{if(!getAuth()){showLogin();return}try{member=await rpc('barberium_staff_me');await showDashboard()}catch(e){console.error(e);clearAuth();showLogin()}})();
