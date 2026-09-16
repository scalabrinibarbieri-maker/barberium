const SUPABASE_URL='https://pmvvawbaqylspxfmxezw.supabase.co';
const SUPABASE_KEY='sb_publishable_CveglntZGjChE89lPcsQcg_EvBnYmKo';
const AUTH_KEY='barberium_staff_auth_v1';

const $=s=>document.querySelector(s);
const moneyCents=n=>new Intl.NumberFormat('pt-BR',{style:'currency',currency:'BRL'}).format((n||0)/100);
const pad=n=>String(n).padStart(2,'0');
const isoDate=d=>`${d.getFullYear()}-${pad(d.getMonth()+1)}-${pad(d.getDate())}`;
let currentDate=isoDate(new Date());
let member=null;

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
  let data=null;
  try{data=text?JSON.parse(text):null}catch{data=text}
  if(!r.ok)throw new Error(data?.message||data?.msg||data?.error_description||data?.error||`Erro ${r.status}`);
  return data;
}

async function rpc(name,payload={}){
  return authFetch(`/rest/v1/rpc/${name}`,{method:'POST',body:JSON.stringify(payload)});
}

async function login(email,password){
  const r=await fetch(`${SUPABASE_URL}/auth/v1/token?grant_type=password`,{
    method:'POST',
    headers:{apikey:SUPABASE_KEY,'Content-Type':'application/json'},
    body:JSON.stringify({email,password})
  });
  const data=await r.json().catch(()=>({}));
  if(!r.ok)throw new Error(data?.error_description||data?.msg||'E-mail ou senha inválidos.');
  saveAuth(data);
  try{
    member=await rpc('barberium_staff_me');
    return member;
  }catch{
    clearAuth();
    throw new Error('Este login não possui acesso à Área da Equipe.');
  }
}

async function logout(){
  try{await authFetch('/auth/v1/logout',{method:'POST',body:'{}'})}catch{}
  clearAuth();member=null;showLogin();
}

function showLogin(){
  $('#loginView').classList.remove('hidden');
  $('#dashboardView').classList.add('hidden');
  $('#password').value='';
}

function showDashboard(){
  $('#loginView').classList.add('hidden');
  $('#dashboardView').classList.remove('hidden');
  const role=member?.role||'barber';
  $('#roleLabel').textContent=role==='owner'?'Proprietário':role==='admin'?'Administrador':'Barbeiro';
  $('#welcomeName').textContent=member?.professional_name?`Olá, ${member.professional_name.split(' ')[0]}.`:'Painel da unidade';
  $('#scopeLabel').textContent=role==='barber'
    ?'Você está vendo apenas a sua própria agenda.'
    :'Você está vendo a agenda de toda a equipe.';
  renderDate();
  loadDashboard();
}

function dateLong(iso){
  const d=new Date(`${iso}T12:00:00`);
  return new Intl.DateTimeFormat('pt-BR',{weekday:'short',day:'2-digit',month:'short'}).format(d).replace(/\./g,'');
}
function renderDate(){
  $('#dateLabel').textContent=dateLong(currentDate);
  $('#dateInput').value=currentDate;
}
function moveDate(days){
  const d=new Date(`${currentDate}T12:00:00`);
  d.setDate(d.getDate()+days);
  currentDate=isoDate(d);
  renderDate();
  loadDashboard();
}

function statusLabel(v){
  return ({confirmed:'Confirmado',completed:'Concluído',cancelled:'Cancelado',no_show:'Não compareceu'})[v]||v;
}
function timeBR(ts){
  return new Intl.DateTimeFormat('pt-BR',{hour:'2-digit',minute:'2-digit',hour12:false,timeZone:'America/Sao_Paulo'}).format(new Date(ts));
}
function escapeHtml(v=''){
  return String(v).replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#039;'}[c]));
}
function whatsappLink(phone=''){
  const d=String(phone).replace(/\D/g,'');
  return d?`https://wa.me/${d.startsWith('55')?d:'55'+d}`:'#';
}

async function loadDashboard(){
  $('#agendaList').innerHTML='<div class="loading">Carregando agenda…</div>';
  try{
    const data=await rpc('barberium_staff_dashboard',{p_date:currentDate});
    renderSummary(data.summary||{});
    renderAgenda(data.appointments||[]);
  }catch(e){
    if(/JWT|token|autenticado|acesso/i.test(e.message)){
      clearAuth();showLogin();$('#loginError').textContent='Sua sessão expirou. Entre novamente.';return;
    }
    $('#agendaList').innerHTML=`<div class="empty">${escapeHtml(e.message)}</div>`;
  }
}

function renderSummary(s){
  const isManager=['owner','admin'].includes(member?.role);
  const cards=[
    `<article class="summary-card"><small>Horários</small><strong>${s.total||0}</strong></article>`,
    `<article class="summary-card"><small>Confirmados</small><strong>${s.confirmed||0}</strong></article>`,
    isManager
      ?`<article class="summary-card gold"><small>Previsto</small><strong>${moneyCents(s.revenue_cents||0)}</strong></article>`
      :`<article class="summary-card"><small>Concluídos</small><strong>${s.completed||0}</strong></article>`
  ];
  $('#summary').innerHTML=cards.join('');
}

function renderAgenda(items){
  if(!items.length){
    $('#agendaList').innerHTML='<div class="empty">Nenhum horário nesta data.</div>';
    return;
  }
  const isManager=['owner','admin'].includes(member?.role);
  $('#agendaList').innerHTML=items.map(a=>{
    const addons=(a.addons||[]).map(x=>x.name).join(' + ');
    const canAct=a.status==='confirmed';
    return `<article class="appt">
      <div class="appt-time"><strong>${timeBR(a.starts_at)}</strong><small>${timeBR(a.ends_at)}</small></div>
      <div class="appt-body">
        <div class="appt-top"><h3>${escapeHtml(a.customer)}</h3><span class="status ${a.status}">${statusLabel(a.status)}</span></div>
        <p class="appt-service">${escapeHtml(a.service)}${addons?` + ${escapeHtml(addons)}`:''}</p>
        <div class="appt-meta">
          ${isManager?`<span>${escapeHtml(a.professional)}</span>`:''}
          <a href="${whatsappLink(a.phone)}" target="_blank" rel="noopener">WhatsApp</a>
          <span>${moneyCents(a.total_price_cents)}</span>
        </div>
        ${canAct?`<div class="appt-actions">
          <button class="done" data-status="completed" data-id="${a.id}">Concluído</button>
          <button data-status="no_show" data-id="${a.id}">Não compareceu</button>
          ${isManager?`<button class="danger" data-status="cancelled" data-id="${a.id}">Cancelar</button>`:''}
        </div>`:''}
      </div>
    </article>`;
  }).join('');
  document.querySelectorAll('[data-status]').forEach(b=>b.addEventListener('click',()=>changeStatus(b.dataset.id,b.dataset.status)));
}

async function changeStatus(id,status){
  const labels={completed:'marcar como concluído',no_show:'marcar como não compareceu',cancelled:'cancelar'};
  if(!confirm(`Deseja ${labels[status]} este horário?`))return;
  try{
    await rpc('barberium_staff_set_appointment_status',{p_appointment_id:id,p_status:status});
    toast('Agenda atualizada.');
    loadDashboard();
  }catch(e){toast(e.message)}
}

$('#loginForm').addEventListener('submit',async e=>{
  e.preventDefault();
  const btn=$('#loginButton');
  btn.disabled=true;btn.textContent='Entrando…';$('#loginError').textContent='';
  try{
    await login($('#email').value.trim(),$('#password').value);
    showDashboard();
  }catch(err){
    $('#loginError').textContent=err.message;
  }finally{
    btn.disabled=false;btn.textContent='Entrar';
  }
});

$('#togglePassword').addEventListener('click',()=>{
  const p=$('#password');
  p.type=p.type==='password'?'text':'password';
  $('#togglePassword').textContent=p.type==='password'?'Ver':'Ocultar';
});
$('#logoutButton').addEventListener('click',logout);
$('#prevDay').addEventListener('click',()=>moveDate(-1));
$('#nextDay').addEventListener('click',()=>moveDate(1));
$('#todayButton').addEventListener('click',()=>{currentDate=isoDate(new Date());renderDate();loadDashboard()});
$('#dateButton').addEventListener('click',()=>{if($('#dateInput').showPicker)$('#dateInput').showPicker();else $('#dateInput').click()});
$('#dateInput').addEventListener('change',()=>{if($('#dateInput').value){currentDate=$('#dateInput').value;renderDate();loadDashboard()}});

(async()=>{
  if(!getAuth()){showLogin();return}
  try{
    member=await rpc('barberium_staff_me');
    showDashboard();
  }catch{
    clearAuth();
    showLogin();
  }
})();
