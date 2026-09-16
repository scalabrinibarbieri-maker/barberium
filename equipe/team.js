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
  $('#performanceNav').classList.toggle('hidden',!can('view_own_revenue'));
  $('#newAppointmentButton').classList.toggle('hidden',!can('create_appointment'));
  $('#newBlockButton').classList.toggle('hidden',!(can('create_block')||can('create_recurring_block')));
  const visibleNav=$$('#teamBottomNav button:not(.hidden)').length;$('#teamBottomNav').classList.toggle('two',visibleNav===2);$('#teamBottomNav').classList.toggle('one',visibleNav===1);
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
    </div>
    ${statusBtns?`<h3 class="section-mini-title">Alterar status</h3><div class="action-row" id="statusActions">${statusBtns}</div>`:''}
    ${history}`;
  $('#editAppointment')?.addEventListener('click',()=>openBookingModal('edit',d));
  $$('[data-new-status]').forEach(b=>b.onclick=()=>changeStatus(d.id,b.dataset.newStatus));
}
function statusButtons(d){
  const options=[];
  if(isManager())['confirmed','completed','no_show','cancelled'].filter(s=>s!==d.status).forEach(s=>options.push(s));
  else if(d.status==='confirmed'){
    if(can('mark_completed'))options.push('completed');if(can('mark_no_show'))options.push('no_show');if(can('cancel_appointment'))options.push('cancelled');
  }
  return options.map(s=>`<button class="${s==='cancelled'?'danger-btn':'soft-btn'}" data-new-status="${s}" type="button">${statusLabel(s)}</button>`).join('');
}
async function changeStatus(id,status){if(!confirm(`Alterar este atendimento para “${statusLabel(status)}”?`))return;try{await rpc('barberium_staff_set_appointment_status',{p_appointment_id:id,p_status:status});toast('Status atualizado.');await loadAgenda();await openAppointmentDetail(id)}catch(e){toast(friendlyError(e))}}
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
  try{const rows=await rpc('barberium_staff_search_customers',{p_query:q});$('#customerResults').innerHTML=rows.length?rows.map(c=>`<button type="button" class="customer-result" data-customer-id="${c.id}"><strong>${esc(c.name)}</strong><small>${c.phone?esc(c.phone):'Cliente cadastrado'}</small></button>`).join(''):'<div class="empty">Nenhum cliente encontrado.</div>';$$('[data-customer-id]').forEach(b=>b.onclick=()=>{const c=rows.find(x=>x.id===b.dataset.customerId);st.customer=c;st.newCustomer=false;$('#selectedCustomerWrap').innerHTML=`<div class="selected-customer"><strong>${esc(c.name)}</strong><small>${c.phone?esc(c.phone):'Cliente selecionado'}</small></div>`;$('#customerResults').innerHTML='';$('#newCustomerFields').classList.add('hidden')})}catch(e){$('#customerResults').innerHTML=`<div class="empty">${esc(friendlyError(e))}</div>`}
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

const ACTION_PERMISSIONS=[['create_appointment','Criar agendamentos'],['cancel_appointment','Cancelar agendamentos'],['edit_service','Alterar serviço'],['edit_addons','Alterar adicionais'],['edit_date','Alterar data'],['edit_time','Alterar horário'],['edit_value','Alterar valor'],['create_block','Criar/editar bloqueio pontual'],['create_recurring_block','Criar/editar bloqueio recorrente'],['edit_internal_note','Adicionar/editar observação interna'],['mark_completed','Marcar como concluído'],['mark_no_show','Marcar como não compareceu']];
const VIEW_PERMISSIONS=[['view_phone','Ver WhatsApp do cliente'],['view_full_name','Ver nome completo'],['view_value','Ver valor do atendimento'],['view_internal_note','Ver observação interna'],['view_customer_history','Ver histórico/resumo do cliente'],['view_birthday','Ver aniversário'],['view_own_revenue','Ver o próprio faturamento']];
async function loadTeam(){if(!isManager())return;$('#teamList').innerHTML='<div class="loading">Carregando equipe…</div>';try{const team=await rpc('barberium_staff_team');$('#teamList').innerHTML=team.map(p=>`<article class="team-card"><img src="../${esc(p.image_path||'assets/logo-sb.webp')}" alt=""><div class="team-info"><h3>${esc(p.name)}</h3><p>${p.login_active?`Login: ${esc(p.login_email||'ativo')}`:'Sem login vinculado'}</p></div><button class="soft-btn" data-permissions="${p.professional_id}">Permissões</button></article>`).join('');$$('[data-permissions]').forEach(b=>b.onclick=()=>openPermissions(team.find(x=>x.professional_id===b.dataset.permissions)))}catch(e){$('#teamList').innerHTML=`<div class="empty">${esc(friendlyError(e))}</div>`}}
function openPermissions(p){openModal('PERMISSÕES',p.name,`<div class="permission-groups"><section class="permission-group"><h3>Ações</h3><div class="permission-list">${ACTION_PERMISSIONS.map(([k,l])=>permRow(k,l,p.permissions?.[k])).join('')}</div></section><section class="permission-group"><h3>Visualização</h3><div class="permission-list">${VIEW_PERMISSIONS.map(([k,l])=>permRow(k,l,p.permissions?.[k])).join('')}</div></section><button id="savePermissions" class="gold-btn">Salvar permissões</button></div>`);$('#savePermissions').onclick=async()=>{const btn=$('#savePermissions');btn.disabled=true;btn.textContent='Salvando…';const perms={};$$('[data-perm]').forEach(i=>perms[i.dataset.perm]=i.checked);try{await rpc('barberium_staff_set_permissions',{p_professional_id:p.professional_id,p_permissions:perms});toast('Permissões atualizadas.');closeModal();loadTeam()}catch(e){toast(friendlyError(e));btn.disabled=false;btn.textContent='Salvar permissões'}}}
function permRow(k,label,on){return `<label class="permission-item"><span>${esc(label)}</span><input data-perm="${k}" type="checkbox" ${on?'checked':''}></label>`}

function switchPanel(panel){currentPanel=panel;$('#agendaPanel').classList.toggle('hidden',panel!=='agenda');$('#performancePanel').classList.toggle('hidden',panel!=='performance');$('#teamPanel').classList.toggle('hidden',panel!=='team');$$('[data-team-panel]').forEach(b=>b.classList.toggle('active',b.dataset.teamPanel===panel));if(panel==='performance')loadPerformance();if(panel==='team')loadTeam();window.scrollTo({top:0,behavior:'smooth'})}

$('#loginForm').addEventListener('submit',async e=>{e.preventDefault();const btn=$('#loginButton');btn.disabled=true;btn.textContent='Entrando…';$('#loginError').textContent='';try{await login($('#email').value.trim(),$('#password').value);await showDashboard()}catch(err){$('#loginError').textContent=err.message}finally{btn.disabled=false;btn.textContent='Entrar'}});
$('#togglePassword').onclick=()=>{const p=$('#password');p.type=p.type==='password'?'text':'password';$('#togglePassword').textContent=p.type==='password'?'Ver':'Ocultar'};
$('#logoutButton').onclick=logout;$('#prevDay').onclick=()=>moveDate(-1);$('#nextDay').onclick=()=>moveDate(1);$('#todayButton').onclick=()=>{currentDate=isoDate(new Date());renderDate();loadAgenda()};$('#dateButton').onclick=()=>{if($('#dateInput').showPicker)$('#dateInput').showPicker();else $('#dateInput').click()};$('#dateInput').onchange=()=>{if($('#dateInput').value){currentDate=$('#dateInput').value;renderDate();loadAgenda()}};
$('#newAppointmentButton').onclick=()=>openBookingModal('create');$('#newBlockButton').onclick=()=>openBlockModal('create');$('#modalClose').onclick=closeModal;$('#modalBackdrop').addEventListener('click',e=>{if(e.target===$('#modalBackdrop'))closeModal()});
$$('[data-team-panel]').forEach(b=>b.onclick=()=>switchPanel(b.dataset.teamPanel));$$('[data-period]').forEach(b=>b.onclick=()=>{activePeriod=b.dataset.period;$$('[data-period]').forEach(x=>x.classList.toggle('active',x===b));loadPerformance()});

(async()=>{if(!getAuth()){showLogin();return}try{member=await rpc('barberium_staff_me');await showDashboard()}catch(e){console.error(e);clearAuth();showLogin()}})();
