// Barberium v12.10 — produtos no Resumo/Desempenho.
// Cirúrgico: não altera agenda, clientes, financeiro, estoque ou checkout.

const V1210_SUPABASE_URL='https://pmvvawbaqylspxfmxezw.supabase.co';
const V1210_SUPABASE_KEY='sb_publishable_CveglntZGjChE89lPcsQcg_EvBnYmKo';
const V1210_AUTH_KEY='barberium_staff_auth_v1';

const v1210$=(s,r=document)=>r.querySelector(s);
const v1210$$=(s,r=document)=>[...r.querySelectorAll(s)];
const v1210Esc=(v='')=>String(v).replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#039;'}[c]));
const v1210Money=n=>new Intl.NumberFormat('pt-BR',{style:'currency',currency:'BRL'}).format((Number(n)||0)/100);
const v1210Pad=n=>String(n).padStart(2,'0');
const v1210Iso=d=>`${d.getFullYear()}-${v1210Pad(d.getMonth()+1)}-${v1210Pad(d.getDate())}`;

let v1210Generation=0;
let v1210Timer=null;
let v1210Observer=null;

function v1210GetAuth(){
  try{return JSON.parse(localStorage.getItem(V1210_AUTH_KEY)||'null')}catch{return null}
}
function v1210SaveAuth(v){
  localStorage.setItem(V1210_AUTH_KEY,JSON.stringify(v));
}
async function v1210AuthFetch(path,opts={}){
  const session=v1210GetAuth();
  const headers={apikey:V1210_SUPABASE_KEY,'Content-Type':'application/json',...(opts.headers||{})};
  if(session?.access_token)headers.Authorization=`Bearer ${session.access_token}`;

  let r=await fetch(`${V1210_SUPABASE_URL}${path}`,{...opts,headers});

  if(r.status===401&&session?.refresh_token){
    const rr=await fetch(`${V1210_SUPABASE_URL}/auth/v1/token?grant_type=refresh_token`,{
      method:'POST',
      headers:{apikey:V1210_SUPABASE_KEY,'Content-Type':'application/json'},
      body:JSON.stringify({refresh_token:session.refresh_token})
    });
    if(rr.ok){
      const refreshed=await rr.json();
      v1210SaveAuth(refreshed);
      headers.Authorization=`Bearer ${refreshed.access_token}`;
      r=await fetch(`${V1210_SUPABASE_URL}${path}`,{...opts,headers});
    }
  }

  const text=await r.text();
  let data=null;
  try{data=text?JSON.parse(text):null}catch{data=text}
  if(!r.ok)throw new Error(data?.message||data?.msg||data?.error_description||data?.error||`Erro ${r.status}`);
  return data;
}
async function v1210Rpc(name,payload={}){
  return v1210AuthFetch(`/rest/v1/rpc/${name}`,{method:'POST',body:JSON.stringify(payload)});
}

function v1210PeriodRange(){
  const kind=v1210$('#periodTabs [data-period].active')?.dataset?.period||'today';
  const now=new Date();
  now.setHours(12,0,0,0);

  if(kind==='today'){
    const x=v1210Iso(now);
    return [x,x];
  }

  if(kind==='week'){
    const d=new Date(now);
    const day=d.getDay();
    const diff=day===0?-6:1-day;
    d.setDate(d.getDate()+diff);
    const e=new Date(d);
    e.setDate(e.getDate()+6);
    return [v1210Iso(d),v1210Iso(e)];
  }

  return [
    v1210Iso(new Date(now.getFullYear(),now.getMonth(),1,12)),
    v1210Iso(new Date(now.getFullYear(),now.getMonth()+1,0,12))
  ];
}

function v1210PerformanceVisible(){
  const panel=v1210$('#performancePanel');
  return panel && !panel.classList.contains('hidden');
}

function v1210Render(d){
  const cards=v1210$('#performanceCards');
  const list=v1210$('#servicesPerformance');
  if(!cards||!list)return;

  const s=d?.summary||{};
  const productSales=Number(s.product_sales)||0;
  const productUnits=Number(s.product_units)||0;

  cards.innerHTML=`
    <article class="performance-card gold">
      <small>Faturamento realizado</small>
      <strong>${v1210Money(s.realized_revenue_cents)}</strong>
      <em>Serviços + produtos</em>
    </article>
    <article class="performance-card">
      <small>Ainda agendado</small>
      <strong>${v1210Money(s.scheduled_revenue_cents)}</strong>
      <em>Horários confirmados</em>
    </article>
    <article class="performance-card">
      <small>Atendimentos</small>
      <strong>${Number(s.completed)||0}</strong>
      <em>Concluídos</em>
    </article>
    <article class="performance-card">
      <small>Produtos vendidos</small>
      <strong>${productUnits}</strong>
      <em>${productSales} venda${productSales===1?'':'s'} concluída${productSales===1?'':'s'}</em>
    </article>
    <article class="performance-card">
      <small>Ticket médio serviços</small>
      <strong>${v1210Money(s.average_ticket_cents)}</strong>
      <em>Sobre atendimentos concluídos</em>
    </article>
    <article class="performance-card">
      <small>Faturamento produtos</small>
      <strong>${v1210Money(s.product_revenue_cents)}</strong>
      <em>Vendas concluídas</em>
    </article>
  `;

  const services=(d?.services||[]).map(x=>`
    <article class="service-stat">
      <div>
        <h3>${v1210Esc(x.service)}</h3>
        <p>${Number(x.appointments)||0} horários • ${Number(x.completed)||0} concluídos</p>
      </div>
      <strong>${v1210Money((Number(x.realized_revenue_cents)||0)+(Number(x.scheduled_revenue_cents)||0))}</strong>
    </article>
  `).join('');

  const products=(d?.products||[]).map(x=>{
    const q=Number(x.quantity)||0;
    return `
      <article class="service-stat">
        <div>
          <h3>${v1210Esc(x.product)}</h3>
          <p>Produto • ${q} unidade${q===1?'':'s'} vendida${q===1?'':'s'}</p>
        </div>
        <strong>${v1210Money(x.revenue_cents)}</strong>
      </article>
    `;
  }).join('');

  list.innerHTML=`<span data-v1210-applied hidden></span>${services}${products}`||
    '<div class="empty">Nenhum atendimento ou produto neste período.</div>';

  if(!services&&!products){
    list.innerHTML='<span data-v1210-applied hidden></span><div class="empty">Nenhum atendimento ou produto neste período.</div>';
  }

  const eyebrow=v1210$('.services-performance .section-head small');
  if(eyebrow)eyebrow.textContent='SERVIÇOS + PRODUTOS';
}

async function v1210Refresh(){
  if(!v1210PerformanceVisible())return;
  const generation=++v1210Generation;
  const [start,end]=v1210PeriodRange();

  try{
    const d=await v1210Rpc('barberium_staff_performance',{
      p_start_date:start,
      p_end_date:end
    });
    if(generation!==v1210Generation||!v1210PerformanceVisible())return;
    v1210Render(d);
  }catch(err){
    // A tela original continua funcionando caso este complemento não consiga carregar.
    console.error('Barberium v12.10 resumo:',err);
  }
}

function v1210Schedule(delay=140){
  clearTimeout(v1210Timer);
  v1210Timer=setTimeout(v1210Refresh,delay);
}

function v1210WatchPerformance(){
  const list=v1210$('#servicesPerformance');
  if(!list||v1210Observer)return;

  v1210Observer=new MutationObserver(()=>{
    if(!v1210PerformanceVisible())return;
    if(list.querySelector('[data-v1210-applied]'))return;
    v1210Schedule(120);
  });
  v1210Observer.observe(list,{childList:true});
}

document.addEventListener('click',e=>{
  if(e.target.closest?.('[data-team-panel="performance"]')){
    v1210Schedule(180);
    return;
  }
  if(e.target.closest?.('#periodTabs [data-period]')){
    v1210Schedule(180);
  }
});

function v1210Boot(){
  v1210WatchPerformance();
  if(v1210PerformanceVisible())v1210Schedule(250);
}

if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',v1210Boot);
else v1210Boot();

setTimeout(v1210Boot,500);
setTimeout(v1210Boot,1400);
