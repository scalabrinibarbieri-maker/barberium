/* Barberium v12.39 · Saldos rápidos por período
   Cirúrgico: nova aba visual no Financeiro sem alterar team.js.
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

  let active=false;
  let managerUI=false;
  let latest=null;
  let requestId=0;

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

  function injectStyles(){
    if($('#barberiumBalancesV1239Style'))return;
    const style=document.createElement('style');
    style.id='barberiumBalancesV1239Style';
    style.textContent=`
      .v1239-panel{display:grid;gap:16px}
      .v1239-filters{
        display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:10px;
        padding:14px;border:1px solid rgba(255,255,255,.08);
        border-radius:18px;background:rgba(255,255,255,.025)
      }
      .v1239-filters .field{margin:0}
      .v1239-unit{grid-column:1/-1}
      .v1239-presets{
        grid-column:1/-1;display:flex;gap:7px;overflow-x:auto;
        padding:1px 0 2px;scrollbar-width:none
      }
      .v1239-presets::-webkit-scrollbar{display:none}
      .v1239-presets button{
        flex:0 0 auto;border:1px solid rgba(214,174,91,.22);
        background:rgba(214,174,91,.055);color:#d9caa9;
        border-radius:999px;padding:8px 11px;font-size:11px;font-weight:750
      }
      .v1239-presets button.active{
        background:#d6ae5b;color:#102016;border-color:#d6ae5b
      }
      .v1239-period{
        display:flex;justify-content:space-between;gap:10px;align-items:end
      }
      .v1239-period small{
        display:block;color:#8f9e95;font-size:9px;letter-spacing:.09em;
        text-transform:uppercase;font-weight:800;margin-bottom:4px
      }
      .v1239-period strong{font-size:16px;color:#f1eadc}
      .v1239-period span{font-size:11px;color:#8f9e95;text-align:right}

      .v1239-categories{
        display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:8px
      }
      .v1239-category{
        min-width:0;border:1px solid rgba(255,255,255,.075);
        border-radius:15px;padding:12px 9px;background:#0c1b13;text-align:center
      }
      .v1239-category small{
        display:block;color:#9b9485;font-size:9px;font-weight:800;
        text-transform:uppercase;letter-spacing:.055em;margin-bottom:5px
      }
      .v1239-category strong{
        display:block;color:#f0e8d8;font-size:14px;white-space:nowrap
      }
      .v1239-category em{
        display:block;color:#6f7d75;font-size:8px;font-style:normal;margin-top:3px
      }

      .v1239-section-head small{
        color:#a59575;font-size:9px;font-weight:800;letter-spacing:.10em
      }
      .v1239-section-head h2{
        margin:4px 0 2px;font-family:var(--serif);font-size:24px;font-weight:550
      }
      .v1239-section-head p{
        margin:0;color:#8f9e95;font-size:11px;line-height:1.45
      }

      .v1239-balances{
        display:grid;grid-auto-flow:column;grid-auto-columns:minmax(126px,148px);
        gap:11px;overflow-x:auto;padding:3px 1px 8px;
        scroll-snap-type:x proximity;scrollbar-width:none
      }
      .v1239-balances::-webkit-scrollbar{display:none}
      .v1239-person{
        scroll-snap-align:start;border:1px solid rgba(255,255,255,.08);
        background:#0b1a12;color:#f2ead9;border-radius:20px;
        padding:14px 10px 13px;text-align:center;min-height:183px;
        display:flex;flex-direction:column;align-items:center;
        transition:transform .18s ease,border-color .18s ease,background .18s ease
      }
      .v1239-person:active{transform:scale(.975)}
      .v1239-person.house{
        border-color:rgba(214,174,91,.38);
        background:linear-gradient(180deg,rgba(214,174,91,.095),#0b1a12 52%)
      }
      .v1239-avatar{
        width:78px;height:78px;border-radius:50%;padding:3px;
        border:2px solid rgba(238,232,218,.78);margin-bottom:9px;
        background:#07140e;box-shadow:0 9px 24px rgba(0,0,0,.24)
      }
      .v1239-person.house .v1239-avatar{border-color:rgba(214,174,91,.75)}
      .v1239-avatar img{
        width:100%;height:100%;border-radius:50%;object-fit:cover;display:block
      }
      .v1239-person strong{
        display:block;width:100%;overflow:hidden;text-overflow:ellipsis;
        white-space:nowrap;font-size:14px;margin-bottom:5px
      }
      .v1239-person b{
        display:block;color:#f4eddf;font-size:17px;line-height:1.1
      }
      .v1239-person.house b{color:#d6ae5b}
      .v1239-person small{
        color:#7f8d84;font-size:8px;margin-top:5px;line-height:1.25
      }

      .v1239-breakdown{
        display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:8px;
        margin-bottom:15px
      }
      .v1239-breakdown article{
        border:1px solid rgba(255,255,255,.075);border-radius:14px;
        padding:10px 8px;background:rgba(255,255,255,.025)
      }
      .v1239-breakdown small{
        display:block;color:#8f9e95;font-size:8px;text-transform:uppercase;
        letter-spacing:.055em;margin-bottom:4px
      }
      .v1239-breakdown strong{font-size:13px}
      .v1239-detail-list{display:grid;gap:8px}
      .v1239-entry{
        display:flex;justify-content:space-between;align-items:flex-start;gap:12px;
        border:1px solid rgba(255,255,255,.075);border-radius:13px;
        padding:11px 12px;background:rgba(255,255,255,.02)
      }
      .v1239-entry h4{margin:0 0 3px;font-size:12px}
      .v1239-entry p{margin:0;color:#8f9e95;font-size:9px;line-height:1.4}
      .v1239-entry strong{flex:0 0 auto;font-size:13px;color:#e7dcc7}
      .v1239-house-lines{display:grid;gap:8px}
      .v1239-house-line{
        display:flex;justify-content:space-between;gap:12px;
        padding:10px 0;border-bottom:1px solid rgba(255,255,255,.07)
      }
      .v1239-house-line span{color:#9aa69f;font-size:11px}
      .v1239-house-line strong{font-size:13px}
      .v1239-house-line.total{
        border-bottom:0;padding-top:14px
      }
      .v1239-house-line.total span,.v1239-house-line.total strong{
        color:#d6ae5b;font-size:15px;font-weight:850
      }
      .v1239-note{
        margin-top:12px;color:#76847c;font-size:9px;line-height:1.45
      }
      @media(max-width:390px){
        .v1239-category strong{font-size:12px}
        .v1239-balances{grid-auto-columns:minmax(118px,138px)}
      }
      @media(prefers-reduced-motion:reduce){
        .v1239-person{transition:none}
      }
    `;
    document.head.appendChild(style);
  }

  function today(){
    const d=new Date();d.setHours(12,0,0,0);return d;
  }

  function presetRange(kind){
    const end=today();
    const start=new Date(end);
    if(kind==='yesterday'){
      start.setDate(start.getDate()-1);
      return [isoDate(start),isoDate(start)];
    }
    if(kind==='7days'){
      start.setDate(start.getDate()-6);
      return [isoDate(start),isoDate(end)];
    }
    if(kind==='month'){
      start.setDate(1);
      return [isoDate(start),isoDate(end)];
    }
    return [isoDate(end),isoDate(end)];
  }

  function periodLabel(start,end){
    const fmt=new Intl.DateTimeFormat('pt-BR',{day:'2-digit',month:'short',year:'numeric'});
    const a=fmt.format(new Date(`${start}T12:00:00`));
    const b=fmt.format(new Date(`${end}T12:00:00`));
    return start===end?a:`${a} — ${b}`;
  }

  function assetUrl(v){
    const s=String(v||'').trim();
    if(!s)return '../barberium.svg';
    if(/^https?:\/\//i.test(s))return s;
    if(s.startsWith('../'))return s;
    return `../${s.replace(/^\.?\//,'')}`;
  }

  function categoryLabel(v){
    return ({services:'Serviços',products:'Produtos',memberships:'Assinaturas'})[v]||'Comissão';
  }

  function statusLabel(v){
    return ({open:'Em aberto',settled:'Paga',paid:'Paga'})[v]||v||'';
  }

  function dateTime(v,tz){
    try{
      return new Intl.DateTimeFormat('pt-BR',{
        timeZone:tz||'America/Sao_Paulo',
        day:'2-digit',month:'2-digit',year:'2-digit',
        hour:'2-digit',minute:'2-digit'
      }).format(new Date(v));
    }catch{return String(v||'')}
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

  function install(){
    const tabs=$('#financeTabs');
    if(!tabs)return;

    if(!$('#v1239BalancesTab')){
      const btn=document.createElement('button');
      btn.id='v1239BalancesTab';
      btn.type='button';
      btn.textContent='Saldos';
      tabs.insertBefore(btn,tabs.firstChild);
      btn.addEventListener('click',openBalances);
    }

    if(!$('#financeBalancesTab')){
      const panel=document.createElement('section');
      panel.id='financeBalancesTab';
      panel.className='finance-tab-panel hidden';
      panel.innerHTML=`
        <div class="v1239-panel">
          <div class="v1239-filters">
            <div class="field">
              <label>De</label>
              <input id="v1239Start" type="date">
            </div>
            <div class="field">
              <label>Até</label>
              <input id="v1239End" type="date">
            </div>
            <div id="v1239UnitWrap" class="field v1239-unit hidden">
              <label>Unidade</label>
              <select id="v1239Unit"></select>
            </div>
            <div class="v1239-presets">
              <button data-v1239-preset="today" type="button">Hoje</button>
              <button data-v1239-preset="yesterday" type="button">Ontem</button>
              <button data-v1239-preset="7days" type="button">7 dias</button>
              <button data-v1239-preset="month" type="button">Este mês</button>
            </div>
          </div>

          <div class="v1239-period">
            <div>
              <small>Período selecionado</small>
              <strong id="v1239PeriodLabel">Hoje</strong>
            </div>
            <span id="v1239ScopeLabel"></span>
          </div>

          <div id="v1239Content"><div class="loading">Carregando saldos…</div></div>
        </div>`;
      tabs.insertAdjacentElement('afterend',panel);

      const [a,b]=presetRange('today');
      $('#v1239Start').value=a;
      $('#v1239End').value=b;

      $('#v1239Start').addEventListener('change',()=>{
        if($('#v1239Start').value>$('#v1239End').value)$('#v1239End').value=$('#v1239Start').value;
        clearPreset();
        loadBalances();
      });
      $('#v1239End').addEventListener('change',()=>{
        if($('#v1239End').value<$('#v1239Start').value)$('#v1239Start').value=$('#v1239End').value;
        clearPreset();
        loadBalances();
      });
      $('#v1239Unit').addEventListener('change',()=>{
        const global=$('#financeUnit');
        if(global)global.value=$('#v1239Unit').value;
        loadBalances();
      });
      $$('[data-v1239-preset]').forEach(btn=>{
        btn.addEventListener('click',()=>{
          const [start,end]=presetRange(btn.dataset.v1239Preset);
          $('#v1239Start').value=start;
          $('#v1239End').value=end;
          $$('[data-v1239-preset]').forEach(x=>x.classList.toggle('active',x===btn));
          loadBalances();
        });
      });
    }

    watchNavigation();
  }

  function clearPreset(){
    $$('[data-v1239-preset]').forEach(x=>x.classList.remove('active'));
  }

  function managerFromUI(){
    return $('#financeTitle')?.textContent?.trim()!=='Minhas comissões';
  }

  function syncUnitOptions(){
    const wrap=$('#v1239UnitWrap');
    const own=$('#v1239Unit');
    if(!wrap||!own)return;

    if(!managerUI){
      wrap.classList.add('hidden');
      own.innerHTML='';
      return;
    }

    const global=$('#financeUnit');
    if(global?.options?.length){
      own.innerHTML=global.innerHTML;
      own.value=global.value||'';
    }
    wrap.classList.remove('hidden');
  }

  function openBalances(){
    active=true;
    managerUI=managerFromUI();

    $$('[data-finance-tab]').forEach(b=>b.classList.remove('active'));
    $('#v1239BalancesTab')?.classList.add('active');
    $$('.finance-tab-panel').forEach(p=>p.classList.add('hidden'));
    $('#financeBalancesTab')?.classList.remove('hidden');

    $('#financeAdminControls')?.classList.add('hidden');
    syncUnitOptions();

    if(!$$('[data-v1239-preset].active').length){
      $('[data-v1239-preset="today"]')?.classList.add('active');
    }

    loadBalances();
  }

  function closeBalances(){
    if(!active)return;
    active=false;
    $('#v1239BalancesTab')?.classList.remove('active');
    $('#financeBalancesTab')?.classList.add('hidden');

    if(managerFromUI()){
      $('#financeAdminControls')?.classList.remove('hidden');
    }
  }

  function watchNavigation(){
    if(document.documentElement.dataset.v1239Watch==='1')return;
    document.documentElement.dataset.v1239Watch='1';

    document.addEventListener('click',e=>{
      if(e.target.closest?.('[data-finance-tab]')){
        closeBalances();
      }

      const panelNav=e.target.closest?.('[data-team-panel]');
      if(panelNav&&panelNav.dataset.teamPanel!=='finance'){
        closeBalances();
      }

      if(panelNav?.dataset.teamPanel==='finance'){
        setTimeout(()=>{
          if(active)closeBalances();
        },80);
      }
    },true);

    const financePanel=$('#financePanel');
    if(financePanel){
      new MutationObserver(()=>{
        if(financePanel.classList.contains('hidden'))closeBalances();
      }).observe(financePanel,{attributes:true,attributeFilter:['class']});
    }
  }

  async function loadBalances(){
    if(!active)return;
    const start=$('#v1239Start')?.value;
    const end=$('#v1239End')?.value;
    if(!start||!end)return;

    const current=++requestId;
    $('#v1239PeriodLabel').textContent=periodLabel(start,end);
    $('#v1239Content').innerHTML='<div class="loading">Carregando saldos…</div>';

    try{
      const data=await rpc('barberium_staff_balance_quick',{
        p_start:start,
        p_end:end,
        p_unit_id:managerUI?($('#v1239Unit')?.value||null):null
      });

      if(current!==requestId||!active)return;
      latest=data;
      render(data);
    }catch(err){
      console.error('Saldos rápidos:',err);
      if(current!==requestId)return;
      $('#v1239Content').innerHTML=`<div class="empty">${esc(err?.message||'Não foi possível carregar os saldos.')}</div>`;
    }
  }

  function render(data){
    const root=$('#v1239Content');
    if(!root)return;

    const pros=data?.professionals||[];
    const role=data?.role||'manager';
    const isManager=role==='manager';
    $('#v1239ScopeLabel').textContent=isManager
      ?'Casa + comissões da equipe'
      :'Sua comissão no período';

    const c=data?.categories||{};
    const brand=$('.brand-line img')?.getAttribute('src')||'../assets/logo-sb.webp';

    const managerCategories=isManager?`
      <div class="v1239-categories">
        <article class="v1239-category">
          <small>Serviços</small>
          <strong>${money(c.services?.net_cents||0)}</strong>
          <em>líquido</em>
        </article>
        <article class="v1239-category">
          <small>Produtos</small>
          <strong>${money(c.products?.net_cents||0)}</strong>
          <em>líquido</em>
        </article>
        <article class="v1239-category">
          <small>Assinaturas</small>
          <strong>${money(c.memberships?.net_cents||0)}</strong>
          <em>líquido</em>
        </article>
      </div>`:'';

    const barberBreakdown=!isManager&&pros[0]?`
      <div class="v1239-categories">
        <article class="v1239-category">
          <small>Serviços</small>
          <strong>${money(pros[0].service_commission_cents||0)}</strong>
          <em>comissão</em>
        </article>
        <article class="v1239-category">
          <small>Produtos</small>
          <strong>${money(pros[0].product_commission_cents||0)}</strong>
          <em>comissão</em>
        </article>
        <article class="v1239-category">
          <small>Assinaturas</small>
          <strong>${money(pros[0].membership_commission_cents||0)}</strong>
          <em>comissão</em>
        </article>
      </div>`:'';

    const house=isManager?`
      <button class="v1239-person house" data-v1239-house type="button">
        <span class="v1239-avatar"><img src="${esc(brand)}" alt=""></span>
        <strong>Casa</strong>
        <b>${money(data.house_cents||0)}</b>
        <small>Líquido − comissões</small>
      </button>`:'';

    const cards=pros.map(p=>`
      <button class="v1239-person" data-v1239-pro="${esc(p.professional_id)}" type="button">
        <span class="v1239-avatar"><img src="${esc(assetUrl(p.image_path))}" alt=""></span>
        <strong>${esc(p.name)}</strong>
        <b>${money(p.commission_cents||0)}</b>
        <small>Comissão no período</small>
      </button>`).join('');

    root.innerHTML=`
      ${managerCategories}
      ${barberBreakdown}
      <div class="v1239-section-head">
        <small>SALDOS</small>
        <h2>${isManager?'Visão rápida':'Seu saldo'}</h2>
        <p>Toque em um card para ver de onde veio o valor.</p>
      </div>
      <div class="v1239-balances">${house}${cards}</div>
      ${!pros.length?'<div class="empty">Nenhum profissional encontrado neste período.</div>':''}
    `;

    $('[data-v1239-house]',root)?.addEventListener('click',()=>showHouse(data));
    $$('[data-v1239-pro]',root).forEach(btn=>{
      btn.addEventListener('click',()=>showProfessional(data,btn.dataset.v1239Pro));
    });
  }

  function showHouse(data){
    const c=data?.categories||{};
    openModal('SALDOS','Casa',`
      <div class="v1239-house-lines">
        <div class="v1239-house-line"><span>Serviços líquidos</span><strong>${money(c.services?.net_cents||0)}</strong></div>
        <div class="v1239-house-line"><span>Produtos líquidos</span><strong>${money(c.products?.net_cents||0)}</strong></div>
        <div class="v1239-house-line"><span>Assinaturas / planos líquidos</span><strong>${money(c.memberships?.net_cents||0)}</strong></div>
        <div class="v1239-house-line"><span>Total recebido líquido</span><strong>${money(data.net_received_cents||0)}</strong></div>
        <div class="v1239-house-line"><span>− Comissões geradas</span><strong>${money(data.commissions_cents||0)}</strong></div>
        <div class="v1239-house-line total"><span>Casa</span><strong>${money(data.house_cents||0)}</strong></div>
      </div>
      <p class="v1239-note">Visão rápida antes das demais despesas operacionais e do custo dos produtos. Para DRE completo, use a aba Visão/Relatórios.</p>
    `);
  }

  function showProfessional(data,id){
    const p=(data?.professionals||[]).find(x=>x.professional_id===id);
    if(!p)return;

    const entries=(data?.entries||[]).filter(x=>x.professional_id===id);

    openModal('COMISSÕES',p.name,`
      <div class="v1239-breakdown">
        <article><small>Serviços</small><strong>${money(p.service_commission_cents||0)}</strong></article>
        <article><small>Produtos</small><strong>${money(p.product_commission_cents||0)}</strong></article>
        <article><small>Assinaturas</small><strong>${money(p.membership_commission_cents||0)}</strong></article>
      </div>
      <div class="v1239-house-line total" style="padding-top:0;margin-bottom:13px">
        <span>Total do período</span><strong>${money(p.commission_cents||0)}</strong>
      </div>
      <div class="v1239-detail-list">
        ${entries.length?entries.map(x=>`
          <article class="v1239-entry">
            <div>
              <h4>${esc(x.description||categoryLabel(x.category))}</h4>
              <p>${esc(categoryLabel(x.category))} • ${esc(dateTime(x.created_at,data.timezone))} • ${esc(statusLabel(x.status))}</p>
            </div>
            <strong>${money(x.amount_cents||0)}</strong>
          </article>
        `).join(''):'<div class="empty">Nenhuma comissão gerada neste período.</div>'}
      </div>
    `);
  }

  function boot(){
    injectStyles();
    install();
  }

  if(document.readyState==='loading'){
    document.addEventListener('DOMContentLoaded',boot,{once:true});
  }else{
    boot();
  }

  setTimeout(boot,300);
  setTimeout(boot,1000);
})();
