/* Barberium v12.33 · Horários livres + Sua comissão no desempenho
   Cirúrgico: acrescenta recursos sem alterar team.js.
*/
(() => {
  const SUPABASE_URL='https://pmvvawbaqylspxfmxezw.supabase.co';
  const SUPABASE_KEY='sb_publishable_CveglntZGjChE89lPcsQcg_EvBnYmKo';
  const AUTH_KEY='barberium_staff_auth_v1';

  const $=(s,r=document)=>r.querySelector(s);
  const $$=(s,r=document)=>[...r.querySelectorAll(s)];
  const pad=n=>String(n).padStart(2,'0');
  const isoDate=d=>`${d.getFullYear()}-${pad(d.getMonth()+1)}-${pad(d.getDate())}`;
  const esc=(v='')=>String(v??'').replace(/[&<>"']/g,c=>({
    '&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#039;'
  }[c]));
  const money=n=>new Intl.NumberFormat('pt-BR',{
    style:'currency',currency:'BRL'
  }).format((Number(n)||0)/100);

  function session(){
    try{return JSON.parse(localStorage.getItem(AUTH_KEY)||'null')}catch{return null}
  }
  function saveSession(v){
    localStorage.setItem(AUTH_KEY,JSON.stringify(v));
  }

  async function authFetch(path,opts={}){
    let s=session();
    const headers={
      apikey:SUPABASE_KEY,
      'Content-Type':'application/json',
      ...(opts.headers||{})
    };
    if(s?.access_token)headers.Authorization=`Bearer ${s.access_token}`;

    let r=await fetch(`${SUPABASE_URL}${path}`,{...opts,headers});

    if(r.status===401&&s?.refresh_token){
      const rr=await fetch(`${SUPABASE_URL}/auth/v1/token?grant_type=refresh_token`,{
        method:'POST',
        headers:{apikey:SUPABASE_KEY,'Content-Type':'application/json'},
        body:JSON.stringify({refresh_token:s.refresh_token})
      });
      if(rr.ok){
        s=await rr.json();
        saveSession(s);
        headers.Authorization=`Bearer ${s.access_token}`;
        r=await fetch(`${SUPABASE_URL}${path}`,{...opts,headers});
      }
    }

    const text=await r.text();
    let data=null;
    try{data=text?JSON.parse(text):null}catch{data=text}
    if(!r.ok){
      throw new Error(
        data?.message||data?.msg||data?.error_description||data?.error||`Erro ${r.status}`
      );
    }
    return data;
  }

  function rpc(name,payload={}){
    return authFetch(`/rest/v1/rpc/${name}`,{
      method:'POST',
      body:JSON.stringify(payload)
    });
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

  function durationLabel(min){
    min=Number(min)||0;
    if(min<60)return `${min} min`;
    const h=Math.floor(min/60),m=min%60;
    return m?`${h}h ${m}min`:`${h}h`;
  }

  function injectStyles(){
    if($('#barberiumV1233Style'))return;
    const style=document.createElement('style');
    style.id='barberiumV1233Style';
    style.textContent=`
      .v1233-free-list{display:grid;gap:14px}
      .v1233-free-pro{
        border:1px solid rgba(255,255,255,.10);
        border-radius:18px;
        padding:15px;
        background:rgba(255,255,255,.025)
      }
      .v1233-free-head{
        display:flex;justify-content:space-between;gap:12px;align-items:flex-start;
        margin-bottom:12px
      }
      .v1233-free-head h3{margin:0;font-size:1rem}
      .v1233-free-head small{display:block;margin-top:4px;color:#98a79e}
      .v1233-free-count{
        flex:0 0 auto;border:1px solid rgba(214,174,91,.30);
        color:#d6ae5b;border-radius:999px;padding:5px 9px;font-size:.75rem
      }
      .v1233-free-ranges{display:grid;gap:8px}
      .v1233-free-range{
        display:flex;align-items:center;justify-content:space-between;gap:12px;
        border-radius:13px;padding:11px 12px;
        background:rgba(214,174,91,.07);
        border:1px solid rgba(214,174,91,.16)
      }
      .v1233-free-range strong{font-size:1rem}
      .v1233-free-range span{color:#98a79e;font-size:.82rem}
      .v1233-free-empty{color:#98a79e;font-size:.9rem;padding:8px 0}
    `;
    document.head.appendChild(style);
  }

  function selectedProfessionalId(){
    const active=$('[data-filter-prof].active');
    return active?.dataset?.filterProf||null;
  }

  async function showFreeRanges(){
    const date=$('#dateInput')?.value||isoDate(new Date());
    const professionalId=selectedProfessionalId();

    openModal(
      'AGENDA',
      'Horários livres',
      '<div class="loading">Buscando horários livres…</div>'
    );

    try{
      const data=await rpc('barberium_staff_free_ranges',{
        p_date:date,
        p_professional_id:professionalId
      });

      const pros=data?.professionals||[];
      if(!pros.length){
        $('#modalBody').innerHTML='<div class="empty">Nenhum profissional disponível para esta data.</div>';
        return;
      }

      const today=isoDate(new Date());

      $('#modalBody').innerHTML=`
        <div class="detail-note">
          <small>DATA</small>
          <p><strong>${esc($('#dateLabel')?.textContent||date)}</strong></p>
          <p>As faixas abaixo já descontam agendamentos que bloqueiam a agenda e bloqueios do profissional.</p>
        </div>
        <div class="v1233-free-list">
          ${pros.map(p=>{
            const ranges=p.ranges||[];
            const closed=p.is_closed===true;
            const emptyText=closed
              ?'Sem expediente nesta data.'
              :(date===today?'Nenhuma faixa livre restante hoje.':'Nenhuma faixa livre nesta data.');

            return `
              <section class="v1233-free-pro">
                <div class="v1233-free-head">
                  <div>
                    <h3>${esc(p.professional)}</h3>
                    <small>${closed?'Sem expediente':`Expediente ${esc(p.open_time)}–${esc(p.close_time)}`}</small>
                  </div>
                  ${!closed?`<span class="v1233-free-count">${ranges.length} faixa${ranges.length===1?'':'s'}</span>`:''}
                </div>
                ${ranges.length?`
                  <div class="v1233-free-ranges">
                    ${ranges.map(r=>`
                      <div class="v1233-free-range">
                        <strong>${esc(r.start)}–${esc(r.end)}</strong>
                        <span>${durationLabel(r.duration_min)} livres</span>
                      </div>
                    `).join('')}
                  </div>
                `:`<div class="v1233-free-empty">${emptyText}</div>`}
              </section>`;
          }).join('')}
        </div>`;
    }catch(err){
      console.error('Horários livres:',err);
      $('#modalBody').innerHTML=`<div class="empty">${esc(err?.message||'Não foi possível carregar os horários livres.')}</div>`;
    }
  }

  function installFreeButton(){
    const actions=$('#agendaPanel .quick-actions');
    if(!actions||$('#v1233FreeTimesButton'))return;

    const btn=document.createElement('button');
    btn.id='v1233FreeTimesButton';
    btn.className='soft-btn small';
    btn.type='button';
    btn.textContent='Horários livres';
    btn.addEventListener('click',showFreeRanges);
    actions.appendChild(btn);
  }

  function periodRange(kind){
    const now=new Date();
    now.setHours(12,0,0,0);

    if(kind==='today'){
      const x=isoDate(now);
      return [x,x];
    }

    if(kind==='week'){
      const d=new Date(now);
      const day=d.getDay();
      const diff=day===0?-6:1-day;
      d.setDate(d.getDate()+diff);
      const e=new Date(d);
      e.setDate(e.getDate()+6);
      return [isoDate(d),isoDate(e)];
    }

    return [
      isoDate(new Date(now.getFullYear(),now.getMonth(),1,12)),
      isoDate(new Date(now.getFullYear(),now.getMonth()+1,0,12))
    ];
  }

  function barberCanSeeCommission(){
    const title=$('#performanceTitle')?.textContent?.trim();
    const finance=$('#financeNav');
    return title==='Seu desempenho'
      && finance
      && !finance.classList.contains('hidden');
  }

  let performanceRequest=0;

  async function ensureCommissionCard(){
    const panel=$('#performancePanel');
    const root=$('#performanceCards');

    if(!panel||!root||panel.classList.contains('hidden'))return;
    if(!barberCanSeeCommission())return;
    if(root.querySelector('.loading'))return;
    if(root.querySelector('.empty')&&!root.querySelector('.performance-card'))return;
    if($('#v1233CommissionCard',root))return;

    const period=$('[data-period].active')?.dataset?.period||'today';
    const [start,end]=periodRange(period);
    const request=++performanceRequest;

    const card=document.createElement('article');
    card.id='v1233CommissionCard';
    card.className='performance-card';
    card.innerHTML='<small>Sua comissão</small><strong>…</strong><em>Calculando período</em>';
    root.appendChild(card);

    try{
      const data=await rpc('barberium_staff_performance_v12_33',{
        p_start_date:start,
        p_end_date:end
      });

      if(request!==performanceRequest)return;

      const activePeriod=$('[data-period].active')?.dataset?.period||'today';
      const [activeStart,activeEnd]=periodRange(activePeriod);
      if(activeStart!==start||activeEnd!==end)return;

      const current=$('#v1233CommissionCard',root);
      if(!current)return;

      current.innerHTML=`
        <small>Sua comissão</small>
        <strong>${money(data?.summary?.commission_cents||0)}</strong>
        <em>Gerada no período</em>`;
    }catch(err){
      console.error('Comissão no desempenho:',err);
      const current=$('#v1233CommissionCard',root);
      if(current){
        current.innerHTML=`
          <small>Sua comissão</small>
          <strong>—</strong>
          <em>Não foi possível carregar</em>`;
      }
    }
  }

  function installPerformanceObserver(){
    const root=$('#performanceCards');
    if(!root||root.dataset.v1233Observed==='1')return;
    root.dataset.v1233Observed='1';

    let timer=null;
    const schedule=()=>{
      clearTimeout(timer);
      timer=setTimeout(ensureCommissionCard,60);
    };

    new MutationObserver(schedule).observe(root,{childList:true,subtree:false});

    document.addEventListener('click',e=>{
      if(
        e.target.closest?.('#performanceNav') ||
        e.target.closest?.('[data-team-panel="performance"]') ||
        e.target.closest?.('[data-period]')
      ){
        setTimeout(schedule,80);
        setTimeout(schedule,300);
      }
    },true);

    schedule();
  }

  function boot(){
    injectStyles();
    installFreeButton();
    installPerformanceObserver();
  }

  if(document.readyState==='loading'){
    document.addEventListener('DOMContentLoaded',boot,{once:true});
  }else{
    boot();
  }

  setTimeout(boot,300);
  setTimeout(boot,1000);
})();
