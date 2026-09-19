/* Barberium v12.30 · Minhas comissões isoladas para barbeiros
   - Intercepta SOMENTE o Financeiro de usuários não-gerentes.
   - Não altera o Financeiro do ADM.
   - Usa RPC dedicada barberium_staff_my_commissions_v12_30().
*/
(() => {
  const SUPABASE_URL='https://pmvvawbaqylspxfmxezw.supabase.co';
  const SUPABASE_KEY='sb_publishable_CveglntZGjChE89lPcsQcg_EvBnYmKo';
  const AUTH_KEY='barberium_staff_auth_v1';
  const $=(s,r=document)=>r.querySelector(s);
  const $$=(s,r=document)=>[...r.querySelectorAll(s)];

  let activeFilter='receivable';
  let lastData=null;
  let loading=false;

  const esc=(v='')=>String(v??'').replace(/[&<>"']/g,c=>({
    '&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#039;'
  }[c]));

  const money=n=>new Intl.NumberFormat('pt-BR',{
    style:'currency',currency:'BRL'
  }).format((Number(n)||0)/100);

  const brDate=v=>{
    if(!v)return '';
    const d=new Date(`${String(v).slice(0,10)}T12:00:00`);
    return new Intl.DateTimeFormat('pt-BR',{
      day:'2-digit',month:'2-digit',year:'numeric'
    }).format(d);
  };

  const dateTime=v=>{
    if(!v)return '';
    return new Intl.DateTimeFormat('pt-BR',{
      timeZone:'America/Sao_Paulo',
      day:'2-digit',month:'2-digit',year:'numeric',
      hour:'2-digit',minute:'2-digit'
    }).format(new Date(v));
  };

  function session(){
    try{return JSON.parse(localStorage.getItem(AUTH_KEY)||'null')}catch{return null}
  }
  function saveSession(v){localStorage.setItem(AUTH_KEY,JSON.stringify(v))}

  function isBarberView(){
    const teamNav=$('#teamNav');
    const financeNav=$('#financeNav');
    return Boolean(
      teamNav &&
      financeNav &&
      teamNav.classList.contains('hidden') &&
      !financeNav.classList.contains('hidden')
    );
  }

  function xhr(method,url,headers={},body=null,timeout=12000){
    return new Promise((resolve,reject)=>{
      const req=new XMLHttpRequest();
      req.open(method,url,true);
      req.timeout=timeout;
      for(const [k,v] of Object.entries(headers)){
        if(v!=null)req.setRequestHeader(k,String(v));
      }
      req.onload=()=>resolve({
        ok:req.status>=200&&req.status<300,
        status:req.status,
        text:req.responseText
      });
      req.onerror=()=>reject(new Error('Falha de conexão.'));
      req.ontimeout=()=>reject(new Error('A conexão demorou mais que o esperado.'));
      req.send(body);
    });
  }

  async function directRpc(name,payload={}){
    let s=session();
    if(!s?.access_token)throw new Error('Sessão expirada. Entre novamente.');

    const headers={
      apikey:SUPABASE_KEY,
      'Content-Type':'application/json',
      Authorization:`Bearer ${s.access_token}`
    };

    let r=await xhr(
      'POST',
      `${SUPABASE_URL}/rest/v1/rpc/${name}`,
      headers,
      JSON.stringify(payload)
    );

    if(r.status===401&&s.refresh_token){
      const rr=await xhr(
        'POST',
        `${SUPABASE_URL}/auth/v1/token?grant_type=refresh_token`,
        {apikey:SUPABASE_KEY,'Content-Type':'application/json'},
        JSON.stringify({refresh_token:s.refresh_token})
      );
      if(rr.ok){
        s=JSON.parse(rr.text||'{}');
        saveSession(s);
        r=await xhr(
          'POST',
          `${SUPABASE_URL}/rest/v1/rpc/${name}`,
          {
            apikey:SUPABASE_KEY,
            'Content-Type':'application/json',
            Authorization:`Bearer ${s.access_token}`
          },
          JSON.stringify(payload)
        );
      }
    }

    let data=null;
    try{data=r.text?JSON.parse(r.text):null}catch{data=r.text}
    if(!r.ok)throw new Error(
      data?.message||data?.msg||data?.error_description||data?.error||`Erro ${r.status}`
    );
    return data;
  }

  function showFinanceShell(){
    ['agendaPanel','performancePanel','clientsPanel','teamPanel','settingsPanel','productsPanel']
      .forEach(id=>$('#'+id)?.classList.add('hidden'));
    $('#financePanel')?.classList.remove('hidden');

    $$('[data-team-panel]').forEach(b=>{
      b.classList.toggle('active',b.dataset.teamPanel==='finance');
    });

    $('#financeTitle').textContent='Minhas comissões';
    $('#financeScope').textContent='Acompanhe somente suas comissões e acertos.';
    $('#financeAdminControls')?.classList.add('hidden');

    $$('[data-finance-tab]').forEach(b=>{
      const commissions=b.dataset.financeTab==='commissions';
      b.classList.toggle('hidden',!commissions);
      b.classList.toggle('active',commissions);
    });

    ['financeOverviewTab','financeCashTab','financeExpensesTab','financePlansTab']
      .forEach(id=>$('#'+id)?.classList.add('hidden'));
    $('#financeCommissionsTab')?.classList.remove('hidden');

    $('#commissionManagerSubtabs')?.classList.add('hidden');
    $('#commissionBarberSubtabs')?.classList.remove('hidden');

    $$('[data-my-commission-filter]').forEach(b=>{
      b.classList.toggle('active',b.dataset.myCommissionFilter===activeFilter);
    });

    window.scrollTo({top:0,behavior:'smooth'});
  }

  function render(){
    const root=$('#commissionContent');
    if(!root||!lastData)return;

    const d=lastData;
    const openEntries=(d.entries||[]).filter(e=>e.status==='open'&&!e.settlement_id);
    const receivable=(d.settlements||[]).filter(x=>x.status!=='paid');
    const paid=(d.settlements||[]).filter(x=>x.status==='paid');

    let body='';
    if(activeFilter==='paid'){
      body=`<h3 class="section-mini-title">Acertos pagos</h3>${
        paid.length
          ? paid.map(x=>`
            <article class="plan-card">
              <div class="plan-head">
                <div>
                  <span class="plan-tag">Pago</span>
                  <h3>${brDate(x.period_start)} — ${brDate(x.period_end)}</h3>
                  <p>${x.closed_at?`Quitado ${dateTime(x.closed_at)}`:'Acerto quitado'}</p>
                </div>
                <strong>${money(x.total_cents)}</strong>
              </div>
            </article>`).join('')
          : '<div class="empty">Nenhum acerto pago neste período.</div>'
      }`;
    }else{
      body=`<h3 class="section-mini-title">Aguardando fechamento</h3>${
        openEntries.length
          ? openEntries.map(e=>`
            <article class="service-stat">
              <div>
                <h3>${esc(e.description||'Comissão')}</h3>
                <p>${dateTime(e.created_at)}</p>
              </div>
              <strong>${money(e.amount_cents)}</strong>
            </article>`).join('')
          : '<div class="empty">Nenhum lançamento aguardando fechamento.</div>'
      }
      <h3 class="section-mini-title">Acertos a receber</h3>${
        receivable.length
          ? receivable.map(x=>`
            <article class="plan-card">
              <div class="plan-head">
                <div>
                  <span class="plan-tag">${esc(x.status||'Em aberto')}</span>
                  <h3>${brDate(x.period_start)} — ${brDate(x.period_end)}</h3>
                  <p>Pago ${money(x.paid_cents)} de ${money(x.total_cents)}</p>
                </div>
                <strong>${money(x.remaining_cents)}</strong>
              </div>
            </article>`).join('')
          : '<div class="empty">Nenhum acerto pendente.</div>'
      }`;
    }

    root.innerHTML=`
      <div class="finance-summary" data-v1230="1">
        <article class="finance-kpi gold">
          <small>A receber</small>
          <strong>${money(d.open_cents)}</strong>
        </article>
        <article class="finance-kpi">
          <small>Ainda não fechado</small>
          <strong>${money(d.unsettled_cents)}</strong>
        </article>
        <article class="finance-kpi">
          <small>Em acertos</small>
          <strong>${money(d.in_settlement_cents)}</strong>
        </article>
      </div>
      ${body}`;
  }

  async function load(){
    if(loading)return;
    loading=true;
    const root=$('#commissionContent');
    if(root)root.innerHTML='<div class="loading">Carregando suas comissões…</div>';

    try{
      lastData=await directRpc('barberium_staff_my_commissions_v12_30',{});
      render();
    }catch(err){
      if(root){
        root.innerHTML=`
          <div class="empty">
            <p>${esc(err?.message||'Não foi possível carregar suas comissões.')}</p>
            <button id="v1230Retry" class="soft-btn" type="button">Tentar novamente</button>
          </div>`;
        $('#v1230Retry')?.addEventListener('click',load);
      }
    }finally{
      loading=false;
    }
  }

  async function open(){
    showFinanceShell();
    await load();
  }

  // Captura antes do onclick original do team.js.
  document.addEventListener('click',event=>{
    if(!isBarberView())return;

    const finance=event.target.closest?.('#financeNav');
    if(finance){
      event.preventDefault();
      event.stopPropagation();
      event.stopImmediatePropagation();
      open();
      return;
    }

    const filter=event.target.closest?.('[data-my-commission-filter]');
    if(filter){
      event.preventDefault();
      event.stopPropagation();
      event.stopImmediatePropagation();
      activeFilter=filter.dataset.myCommissionFilter||'receivable';
      $$('[data-my-commission-filter]').forEach(b=>{
        b.classList.toggle('active',b===filter);
      });
      if(lastData)render();else load();
    }
  },true);
})();
