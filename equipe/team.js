const SUPABASE_URL='https://pmvvawbaqylspxfmxezw.supabase.co';
const SUPABASE_KEY='sb_publishable_CveglntZGjChE89lPcsQcg_EvBnYmKo';
const AUTH_KEY='barberium_staff_auth_v1';

const $=s=>document.querySelector(s);
const moneyCents=n=>new Intl.NumberFormat('pt-BR',{style:'currency',currency:'BRL'}).format((n||0)/100);
const pad=n=>String(n).padStart(2,'0');
const isoDate=d=>`${d.getFullYear()}-${pad(d.getMonth()+1)}-${pad(d.getDate())}`;
let currentDate=isoDate(new Date());
let member=null;
let activePeriod='today';

function getAuth(){try{return JSON.parse(localStorage.getItem(AUTH_KEY)||'null')}catch{return null}}
function saveAuth(v){localStorage.setItem(AUTH_KEY,JSON.stringify(v))}
function clearAuth(){localStorage.removeItem(AUTH_KEY)}
function toast(msg){const e=$('#toast');e.textContent=msg;e.classList.add('show');clearTimeout(toast.t);toast.t=setTimeout(()=>e.classList.remove('show'),2200)}

async function authFetch(path,opts={}){
  const session=getAuth();
  const headers={apikey:SUPABASE_KEY,'Content-Type':'application/json',...(opts.headers||{})};
  if(session?.access_token)headers.Authorization=`Bearer ${session.access_token}`;
  let r=await fetch(`${SUPABASE_URL}${path}`,{...opts,headers});
  if(r.status===401 && session?.refresh_token){
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
  const data=await r.json().catch(()=>({}));
  if(!r.ok)throw new Error(data?.error_description||data?.msg||'E-mail ou senha inválidos.');
  saveAuth(data);
  try{member=await rpc('barberium_staff_me');return member}catch{clearAuth();throw new Error('Este login não possui acesso à Área da Equipe.')}
}

async function logout(){try{await authFetch('/auth/v1/logout',{method:'POST',body:'{}'})}catch{}clearAuth();member=null;showLogin()}
function showLogin(){$('#loginView').classList.remove('hidden');$('#dashboardView').classList.add('hidden');$('#password').value=''}

function roleName(){return member?.role==='owner'?'Proprietário':member?.role==='admin'?'Administrador':'Barbeiro'}
function showDashboard(){
  $('#loginView').classList.add('hidden');$('#dashboardView').classList.remove('hidden');
  $('#roleLabel').textContent=roleName();$('#performanceRole').textContent=roleName();
  $('#welcomeName').textContent=member?.professional_name?`Olá, ${member.professional_name.split(' ')[0]}.`:'Painel da unidade';
  $('#scopeLabel').textContent=member?.role==='barber'?'Você está vendo apenas a sua própria agenda.':'Você está vendo a agenda de toda a equipe.';
  $('#performanceTitle').textContent=member?.role==='barber'?'Seu desempenho':'Desempenho da unidade';
  $('#performanceScope').textContent=member?.role==='barber'?'Somente seus atendimentos e seu faturamento entram nestes números.':'Resumo financeiro e operacional da equipe.';
  renderDate();loadDashboard();
}

function dateLong(iso){const d=new Date(`${iso}T12:00:00`);return new Intl.DateTimeFormat('pt-BR',{weekday:'short',day:'2-digit',month:'short'}).format(d).replace(/\./g,'')}
function dateShort(iso){const d=new Date(`${iso}T12:00:00`);return new Intl.DateTimeFormat('pt-BR',{day:'2-digit',month:'short'}).format(d).replace(/\./g,'')}
function renderDate(){$('#dateLabel').textContent=dateLong(currentDate);$('#dateInput').value=currentDate}
function moveDate(days){const d=new Date(`${currentDate}T12:00:00`);d.setDate(d.getDate()+days);currentDate=isoDate(d);renderDate();loadDashboard()}
function statusLabel(v){return({confirmed:'Confirmado',completed:'Concluído',cancelled:'Cancelado',no_show:'Não compareceu'})[v]||v}
function timeBR(ts){return new Intl.DateTimeFormat('pt-BR',{hour:'2-digit',minute:'2-digit',hour12:false,timeZone:'America/Sao_Paulo'}).format(new Date(ts))}
function escapeHtml(v=''){return String(v).replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#039;'}[c]))}
function whatsappLink(phone=''){const d=String(phone).replace(/\D/g,'');return d?`https://wa.me/${d.startsWith('55')?d:'55'+d}`:'#'}

async function loadDashboard(){
  $('#agendaList').innerHTML='<div class="loading">Carregando agenda…</div>';
  try{const data=await rpc('barberium_staff_dashboard',{p_date:currentDate});renderSummary(data.summary||{});renderAgenda(data.appointments||[])}
  catch(e){if(/JWT|token|autenticado|acesso/i.test(e.message)){clearAuth();showLogin();$('#loginError').textContent='Sua sessão expirou. Entre novamente.';return}$('#agendaList').innerHTML=`<div class="empty">${escapeHtml(e.message)}</div>`}
}

function renderSummary(s){
  const isBarber=member?.role==='barber';
  const cards=isBarber?[
    `<article class="summary-card"><small>Horários</small><strong>${s.total||0}</strong></article>`,
    `<article class="summary-card gold"><small>Realizado</small><strong>${moneyCents(s.realized_revenue_cents||0)}</strong></article>`,
    `<article class="summary-card"><small>Agendado</small><strong>${moneyCents(s.scheduled_revenue_cents||0)}</strong></article>`
  ]:[
    `<article class="summary-card"><small>Horários</small><strong>${s.total||0}</strong></article>`,
    `<article class="summary-card"><small>Confirmados</small><strong>${s.confirmed||0}</strong></article>`,
    `<article class="summary-card gold"><small>Previsto</small><strong>${moneyCents(s.revenue_cents||0)}</strong></article>`
  ];
  $('#summary').innerHTML=cards.join('');
}

function renderAgenda(items){
  if(!items.length){$('#agendaList').innerHTML='<div class="empty">Nenhum horário nesta data.</div>';return}
  const isManager=['owner','admin'].includes(member?.role);
  $('#agendaList').innerHTML=items.map(a=>{
    const addons=(a.addons||[]).map(x=>x.name).join(' + ');
    let actions='';
    if(isManager){
      const buttons=[];
      if(a.status!=='confirmed')buttons.push(`<button data-status="confirmed" data-id="${a.id}">Confirmar</button>`);
      if(a.status!=='completed')buttons.push(`<button class="done" data-status="completed" data-id="${a.id}">Concluído</button>`);
      if(a.status!=='no_show')buttons.push(`<button data-status="no_show" data-id="${a.id}">Não compareceu</button>`);
      if(a.status!=='cancelled')buttons.push(`<button class="danger" data-status="cancelled" data-id="${a.id}">Cancelar</button>`);
      actions=`<div class="appt-actions">${buttons.join('')}</div>`;
    }else if(a.status==='confirmed'){
      actions=`<div class="appt-actions"><button class="done" data-status="completed" data-id="${a.id}">Concluído</button><button data-status="no_show" data-id="${a.id}">Não compareceu</button></div>`;
    }
    return `<article class="appt"><div class="appt-time"><strong>${timeBR(a.starts_at)}</strong><small>${timeBR(a.ends_at)}</small></div><div class="appt-body"><div class="appt-top"><h3>${escapeHtml(a.customer)}</h3><span class="status ${a.status}">${statusLabel(a.status)}</span></div><p class="appt-service">${escapeHtml(a.service)}${addons?` + ${escapeHtml(addons)}`:''}</p><div class="appt-meta">${isManager?`<span>${escapeHtml(a.professional)}</span>`:''}<a href="${whatsappLink(a.phone)}" target="_blank" rel="noopener">WhatsApp</a><span>${moneyCents(a.total_price_cents)}</span></div>${actions}</div></article>`;
  }).join('');
  document.querySelectorAll('[data-status]').forEach(b=>b.addEventListener('click',()=>changeStatus(b.dataset.id,b.dataset.status)));
}

async function changeStatus(id,status){const labels={confirmed:'confirmar novamente',completed:'marcar como concluído',no_show:'marcar como não compareceu',cancelled:'cancelar'};if(!confirm(`Deseja ${labels[status]} este horário?`))return;try{await rpc('barberium_staff_set_appointment_status',{p_appointment_id:id,p_status:status});toast('Agenda atualizada.');loadDashboard();if(!$('#performancePanel').classList.contains('hidden'))loadPerformance()}catch(e){toast(e.message)}}

function periodRange(kind){
  const now=new Date();now.setHours(12,0,0,0);
  if(kind==='today'){const x=isoDate(now);return[start=x,end=x]}
  if(kind==='week'){const d=new Date(now);const day=d.getDay();const diff=day===0?-6:1-day;d.setDate(d.getDate()+diff);const start=isoDate(d);const e=new Date(d);e.setDate(e.getDate()+6);return[start,isoDate(e)]}
  const start=new Date(now.getFullYear(),now.getMonth(),1,12);const end=new Date(now.getFullYear(),now.getMonth()+1,0,12);return[isoDate(start),isoDate(end)]
}

async function loadPerformance(){
  const [start,end]=periodRange(activePeriod);
  $('#periodLabel').textContent=start===end?dateLong(start):`${dateShort(start)} — ${dateShort(end)}`;
  $('#performanceCards').innerHTML='<div class="loading" style="grid-column:1/-1">Carregando desempenho…</div>';
  $('#servicesPerformance').innerHTML='<div class="loading">Carregando serviços…</div>';
  try{const data=await rpc('barberium_staff_performance',{p_start_date:start,p_end_date:end});renderPerformance(data.summary||{},data.services||[])}catch(e){$('#performanceCards').innerHTML=`<div class="empty" style="grid-column:1/-1">${escapeHtml(e.message)}</div>`;$('#servicesPerformance').innerHTML=''}
}

function renderPerformance(s,services){
  $('#performanceCards').innerHTML=[
    `<article class="performance-card gold"><small>Faturamento realizado</small><strong>${moneyCents(s.realized_revenue_cents||0)}</strong><em>Horários concluídos</em></article>`,
    `<article class="performance-card"><small>Ainda agendado</small><strong>${moneyCents(s.scheduled_revenue_cents||0)}</strong><em>Horários confirmados</em></article>`,
    `<article class="performance-card"><small>Atendimentos</small><strong>${s.completed||0}</strong><em>Concluídos no período</em></article>`,
    `<article class="performance-card"><small>Ticket médio</small><strong>${moneyCents(s.average_ticket_cents||0)}</strong><em>Sobre concluídos</em></article>`
  ].join('');
  if(!services.length){$('#servicesPerformance').innerHTML='<div class="empty">Nenhum atendimento neste período.</div>';return}
  $('#servicesPerformance').innerHTML=services.map(x=>`<article class="service-stat"><div><h3>${escapeHtml(x.service)}</h3><p>${x.appointments} ${x.appointments===1?'horário':'horários'} • ${x.completed} concluído${x.completed===1?'':'s'}</p></div><strong>${moneyCents((x.realized_revenue_cents||0)+(x.scheduled_revenue_cents||0))}</strong></article>`).join('');
}

function switchPanel(panel){
  const agenda=panel==='agenda';$('#agendaPanel').classList.toggle('hidden',!agenda);$('#performancePanel').classList.toggle('hidden',agenda);
  document.querySelectorAll('[data-team-panel]').forEach(b=>b.classList.toggle('active',b.dataset.teamPanel===panel));
  if(!agenda)loadPerformance();
}

$('#loginForm').addEventListener('submit',async e=>{e.preventDefault();const btn=$('#loginButton');btn.disabled=true;btn.textContent='Entrando…';$('#loginError').textContent='';try{await login($('#email').value.trim(),$('#password').value);showDashboard()}catch(err){$('#loginError').textContent=err.message}finally{btn.disabled=false;btn.textContent='Entrar'}});
$('#togglePassword').addEventListener('click',()=>{const p=$('#password');p.type=p.type==='password'?'text':'password';$('#togglePassword').textContent=p.type==='password'?'Ver':'Ocultar'});
$('#logoutButton').addEventListener('click',logout);$('#prevDay').addEventListener('click',()=>moveDate(-1));$('#nextDay').addEventListener('click',()=>moveDate(1));$('#todayButton').addEventListener('click',()=>{currentDate=isoDate(new Date());renderDate();loadDashboard()});$('#dateButton').addEventListener('click',()=>{if($('#dateInput').showPicker)$('#dateInput').showPicker();else $('#dateInput').click()});$('#dateInput').addEventListener('change',()=>{if($('#dateInput').value){currentDate=$('#dateInput').value;renderDate();loadDashboard()}});
document.querySelectorAll('[data-team-panel]').forEach(b=>b.addEventListener('click',()=>switchPanel(b.dataset.teamPanel)));
document.querySelectorAll('[data-period]').forEach(b=>b.addEventListener('click',()=>{activePeriod=b.dataset.period;document.querySelectorAll('[data-period]').forEach(x=>x.classList.toggle('active',x===b));loadPerformance()}));

(async()=>{if(!getAuth()){showLogin();return}try{member=await rpc('barberium_staff_me');showDashboard()}catch{clearAuth();showLogin()}})();
