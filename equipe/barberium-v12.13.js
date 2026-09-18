// Barberium v12.13 — múltiplos serviços na mesma comanda (Área da Equipe).
// Camada cirúrgica: mantém team.js intacto e amplia somente o fluxo de agendamento manual.

const V1212_SUPABASE_URL='https://pmvvawbaqylspxfmxezw.supabase.co';
const V1212_SUPABASE_KEY='sb_publishable_CveglntZGjChE89lPcsQcg_EvBnYmKo';
const V1212_AUTH_KEY='barberium_staff_auth_v1';

const v1212$=(s,r=document)=>r.querySelector(s);
const v1212$$=(s,r=document)=>[...r.querySelectorAll(s)];
const v1212Esc=(v='')=>String(v).replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#039;'}[c]));
const v1212Money=n=>new Intl.NumberFormat('pt-BR',{style:'currency',currency:'BRL'}).format((Number(n)||0)/100);

let v1212Catalog=null;
let v1212ExtraIds=new Set();
let v1212ExtraSnapshots=new Map();
let v1212LastDetail=null;
let v1212ActiveForm=null;

const v1212NativeFetch=window.fetch.bind(window);

function v1212GetAuth(){
  try{return JSON.parse(localStorage.getItem(V1212_AUTH_KEY)||'null')}catch{return null}
}
function v1212SaveAuth(v){
  localStorage.setItem(V1212_AUTH_KEY,JSON.stringify(v));
}
async function v1212AuthFetch(path,opts={}){
  const session=v1212GetAuth();
  const headers={apikey:V1212_SUPABASE_KEY,'Content-Type':'application/json',...(opts.headers||{})};
  if(session?.access_token)headers.Authorization=`Bearer ${session.access_token}`;

  let r=await v1212NativeFetch(`${V1212_SUPABASE_URL}${path}`,{...opts,headers});
  if(r.status===401&&session?.refresh_token){
    const rr=await v1212NativeFetch(`${V1212_SUPABASE_URL}/auth/v1/token?grant_type=refresh_token`,{
      method:'POST',
      headers:{apikey:V1212_SUPABASE_KEY,'Content-Type':'application/json'},
      body:JSON.stringify({refresh_token:session.refresh_token})
    });
    if(rr.ok){
      const refreshed=await rr.json();
      v1212SaveAuth(refreshed);
      headers.Authorization=`Bearer ${refreshed.access_token}`;
      r=await v1212NativeFetch(`${V1212_SUPABASE_URL}${path}`,{...opts,headers});
    }
  }

  const text=await r.text();
  let data=null;
  try{data=text?JSON.parse(text):null}catch{data=text}
  if(!r.ok)throw new Error(data?.message||data?.msg||data?.error_description||data?.error||`Erro ${r.status}`);
  return data;
}
async function v1212Rpc(name,payload={}){
  return v1212AuthFetch(`/rest/v1/rpc/${name}`,{method:'POST',body:JSON.stringify(payload)});
}
async function v1212LoadCatalog(){
  if(v1212Catalog)return v1212Catalog;
  v1212Catalog=await v1212Rpc('barberium_staff_catalog');
  return v1212Catalog;
}
function v1212Service(id){
  return (v1212Catalog?.services||[]).find(s=>s.id===id);
}
function v1212Allowed(service,professionalId){
  return !professionalId||!Array.isArray(service?.professional_ids)||service.professional_ids.includes(professionalId);
}
function v1212SelectedAddonIds(){
  return v1212$$('#addonOptions input:checked').map(x=>x.value);
}
function v1212SafeExtraIds(payload={}){
  const main=payload.p_service_id||v1212$('#bookingService')?.value||null;
  const professional=payload.p_professional_id||v1212$('#bookingProfessional')?.value||null;
  const addons=new Set(payload.p_addon_service_ids||v1212SelectedAddonIds());
  const ids=[...v1212ExtraIds].filter(id=>id!==main&&!addons.has(id));
  return ids.filter(id=>{
    const service=v1212Service(id);
    return !service||v1212Allowed(service,professional);
  });
}

const V1212_RPC_MAP={
  barberium_staff_available_slots:'barberium_staff_available_slots_v12_12',
  barberium_staff_create_appointment:'barberium_staff_create_appointment_v12_12',
  barberium_staff_create_walk_in:'barberium_staff_create_walk_in_v12_12',
  barberium_staff_update_appointment:'barberium_staff_update_appointment_v12_12',
  barberium_staff_update_walk_in:'barberium_staff_update_walk_in_v12_12'
};

window.fetch=async function(input,init={}){
  const url=typeof input==='string'?input:input?.url;
  const match=typeof url==='string'?url.match(/\/rest\/v1\/rpc\/([^?]+)/):null;
  const originalRpc=match?.[1]||null;

  let nextInput=input;
  let nextInit=init;

  const activeBookingForm=v1212$('#bookingForm');
  if(activeBookingForm&&activeBookingForm!==v1212ActiveForm){
    v1212ActiveForm=activeBookingForm;
    v1212ExtraIds=new Set();
    v1212ExtraSnapshots=new Map();
  }

  if(originalRpc&&V1212_RPC_MAP[originalRpc]&&init?.body&&activeBookingForm){
    try{
      const body=typeof init.body==='string'?JSON.parse(init.body):init.body;
      const extras=v1212SafeExtraIds(body);
      const patched={...body,p_extra_service_ids:extras};
      nextInput=url.replace(`/rpc/${originalRpc}`,`/rpc/${V1212_RPC_MAP[originalRpc]}`);
      nextInit={...init,body:JSON.stringify(patched)};
    }catch(e){
      console.error('Barberium v12.12 payload:',e);
    }
  }

  const response=await v1212NativeFetch(nextInput,nextInit);

  if(originalRpc==='barberium_staff_appointment_detail'&&response.ok){
    response.clone().json().then(detail=>{
      v1212LastDetail=detail;
    }).catch(()=>{});
  }

  return response;
};

function v1212AvailableServices(){
  const main=v1212$('#bookingService')?.value||null;
  const professional=v1212$('#bookingProfessional')?.value||null;
  const addons=new Set(v1212SelectedAddonIds());

  return (v1212Catalog?.services||[]).filter(s=>
    s.id!==main &&
    !v1212ExtraIds.has(s.id) &&
    !addons.has(s.id) &&
    v1212Allowed(s,professional)
  );
}

function v1212ExtraInfo(id){
  const live=v1212Service(id);
  if(live)return {
    id,
    name:live.name,
    price_cents:Number(live.price_cents)||0,
    duration_min:Number(live.duration_min)||0
  };
  return v1212ExtraSnapshots.get(id)||{id,name:'Serviço',price_cents:0,duration_min:0};
}

function v1212RenderPicker(){
  const select=v1212$('#v1212ServiceSelect');
  if(!select)return;

  const rows=v1212AvailableServices();
  select.innerHTML=rows.length
    ?`<option value="">Selecione outro serviço</option>${rows.map(s=>`<option value="${s.id}">${v1212Esc(s.name)} • ${v1212Money(s.price_cents)}</option>`).join('')}`
    :'<option value="">Nenhum outro serviço disponível</option>';

  v1212$('#v1212ConfirmService').disabled=!rows.length;
}

function v1212RenderSelected(){
  const root=v1212$('#v1212SelectedServices');
  if(!root)return;

  const ids=[...v1212ExtraIds];
  const canEdit=!v1212$('#bookingService')?.disabled;

  root.innerHTML=ids.length
    ?ids.map(id=>{
      const s=v1212ExtraInfo(id);
      return `<div class="unit-breakdown-row">
        <span><strong>${v1212Esc(s.name)}</strong><small>${v1212Money(s.price_cents)} • ${s.duration_min} min</small></span>
        <button class="soft-btn small" data-v1212-remove-service="${id}" type="button" ${canEdit?'':'disabled'}>Remover</button>
      </div>`;
    }).join('')
    :'<div class="empty">Nenhum outro serviço adicionado.</div>';

  v1212$$('[data-v1212-remove-service]').forEach(btn=>{
    btn.onclick=()=>{
      v1212ExtraIds.delete(btn.dataset.v1212RemoveService);
      v1212RenderSelected();
      v1212RenderPicker();
      v1212SyncPrice(true);
      v1212RefreshSlots();
    };
  });
}

function v1212ListedCents(){
  const mainId=v1212$('#bookingService')?.value;
  const main=v1212Service(mainId);
  if(!main)return 0;

  let total=Number(main.price_cents)||0;
  const addonIds=v1212SelectedAddonIds();
  for(const id of addonIds){
    const a=(main.addons||[]).find(x=>x.service_id===id);
    total+=Number(a?.price_cents)||0;
  }
  for(const id of v1212SafeExtraIds()){
    total+=Number(v1212ExtraInfo(id).price_cents)||0;
  }
  return total;
}

function v1212SyncPrice(resetFinal){
  const listed=v1212ListedCents();
  const listedEl=v1212$('#listedPrice');
  if(listedEl)listedEl.textContent=v1212Money(listed);

  const final=v1212$('#finalPrice');
  if(resetFinal&&final&&!final.disabled){
    final.value=(listed/100).toFixed(2);
    final.dispatchEvent(new Event('input',{bubbles:true}));
  }
}

function v1212RefreshSlots(){
  const date=v1212$('#bookingDate');
  const time=v1212$('#bookingTime');
  if(!date||!time||time.tagName!=='SELECT')return;
  setTimeout(()=>date.dispatchEvent(new Event('change',{bubbles:true})),0);
}

function v1212SanitizeExtras(showToast=false){
  const before=v1212ExtraIds.size;
  const main=v1212$('#bookingService')?.value||null;
  const professional=v1212$('#bookingProfessional')?.value||null;
  const addons=new Set(v1212SelectedAddonIds());

  v1212ExtraIds=new Set([...v1212ExtraIds].filter(id=>{
    if(id===main||addons.has(id))return false;
    const service=v1212Service(id);
    return !service||v1212Allowed(service,professional);
  }));

  if(showToast&&v1212ExtraIds.size<before){
    const toast=v1212$('#toast');
    if(toast){
      toast.textContent='Um serviço foi removido porque não é compatível com esta seleção.';
      toast.classList.add('show');
      setTimeout(()=>toast.classList.remove('show'),2600);
    }
  }
  return v1212ExtraIds.size!==before;
}

async function v1212InjectBooking(){
  const form=v1212$('#bookingForm');
  if(!form||form.dataset.v1212Ready==='1')return;

  form.dataset.v1212Ready='1';
  v1212ActiveForm=form;

  try{
    await v1212LoadCatalog();
  }catch(e){
    console.error('Barberium v12.12 catálogo:',e);
    form.dataset.v1212Ready='0';
    return;
  }

  const editing=(v1212$('#saveBooking')?.textContent||'').includes('Salvar alterações');
  const existing=editing?(v1212LastDetail?.extra_services||[]):[];

  v1212ExtraIds=new Set(existing.map(x=>x.service_id));
  v1212ExtraSnapshots=new Map(existing.map(x=>[x.service_id,{
    id:x.service_id,
    name:x.name,
    price_cents:Number(x.price_cents)||0,
    duration_min:Number(x.duration_min)||0
  }]));

  const serviceField=v1212$('#bookingService')?.closest('.field');
  if(!serviceField)return;

  const wrap=document.createElement('div');
  wrap.id='v1212ExtraServiceBox';
  wrap.className='field';
  wrap.innerHTML=`
    <label>Serviços da comanda</label>
    <div id="v1212SelectedServices" class="unit-breakdown"></div>
    <button id="v1212AddService" class="soft-btn" type="button" ${v1212$('#bookingService')?.disabled?'disabled':''}>+ Adicionar serviço</button>
    <div id="v1212ServicePicker" class="form-grid hidden">
      <div class="field">
        <label>Outro serviço</label>
        <select id="v1212ServiceSelect"></select>
      </div>
      <button id="v1212ConfirmService" class="soft-btn" type="button">Adicionar à comanda</button>
    </div>
  `;
  serviceField.insertAdjacentElement('afterend',wrap);

  v1212RenderSelected();
  v1212RenderPicker();
  v1212SyncPrice(false);
  if(existing.length)v1212RefreshSlots();

  v1212$('#v1212AddService').onclick=()=>{
    const picker=v1212$('#v1212ServicePicker');
    picker.classList.toggle('hidden');
    if(!picker.classList.contains('hidden'))v1212RenderPicker();
  };

  v1212$('#v1212ConfirmService').onclick=()=>{
    const select=v1212$('#v1212ServiceSelect');
    const id=select.value;
    if(!id)return;
    v1212ExtraIds.add(id);
    v1212$('#v1212ServicePicker').classList.add('hidden');
    v1212RenderSelected();
    v1212RenderPicker();
    v1212SyncPrice(true);
    v1212RefreshSlots();
  };

  v1212$('#bookingService')?.addEventListener('change',()=>{
    setTimeout(()=>{
      const changed=v1212SanitizeExtras(false);
      v1212RenderSelected();
      v1212RenderPicker();
      v1212SyncPrice(true);
      if(changed)v1212RefreshSlots();
    },0);
  });

  v1212$('#bookingProfessional')?.addEventListener('change',()=>{
    setTimeout(()=>{
      const changed=v1212SanitizeExtras(true);
      v1212RenderSelected();
      v1212RenderPicker();
      v1212SyncPrice(true);
      if(changed)v1212RefreshSlots();
    },0);
  });

  v1212$('#addonOptions')?.addEventListener('change',()=>{
    setTimeout(()=>{
      const changed=v1212SanitizeExtras(false);
      v1212RenderSelected();
      v1212RenderPicker();
      v1212SyncPrice(true);
      if(changed)v1212RefreshSlots();
    },0);
  });
}

function v1212Boot(){
  const modal=v1212$('#modalBody');
  if(!modal)return;

  const observer=new MutationObserver(()=>{
    if(v1212$('#bookingForm'))v1212InjectBooking();
  });
  observer.observe(modal,{childList:true,subtree:true});

  if(v1212$('#bookingForm'))v1212InjectBooking();
}

if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',v1212Boot);
else v1212Boot();
