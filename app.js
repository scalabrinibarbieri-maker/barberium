const BARBERIUM_BUILD='v7-team-area';
const SUPABASE_URL='https://pmvvawbaqylspxfmxezw.supabase.co';
const SUPABASE_KEY='sb_publishable_CveglntZGjChE89lPcsQcg_EvBnYmKo';
const SHOP_SLUG='scalabrini-barbieri';
const UNIT_SLUG='braganca-paulista';
const SESSION_KEY='barberium_scalabrini_session_v1';

let SERVICES=[];
let PROFESSIONALS=[];
let CATALOG=null;
let portalAppointments=[];

const state={
  view:'home',bookingStep:1,bookingMode:'new',editingBookingId:null,
  booking:{serviceId:null,addons:[],professionalId:null,date:null,time:null,customer:null},
  appointmentsTab:'upcoming'
};

const $=(s,r=document)=>r.querySelector(s);
const $$=(s,r=document)=>[...r.querySelectorAll(s)];
const money=n=>new Intl.NumberFormat('pt-BR',{style:'currency',currency:'BRL'}).format(n);
const moneyCents=n=>money((n||0)/100);
const pad=n=>String(n).padStart(2,'0');
const getSession=()=>JSON.parse(localStorage.getItem(SESSION_KEY)||'null');
const saveSession=s=>localStorage.setItem(SESSION_KEY,JSON.stringify(s));
const clearSession=()=>localStorage.removeItem(SESSION_KEY);

async function rpc(name,payload={}){
  const r=await fetch(`${SUPABASE_URL}/rest/v1/rpc/${name}`,{
    method:'POST',
    headers:{'Content-Type':'application/json','apikey':SUPABASE_KEY,'Authorization':`Bearer ${SUPABASE_KEY}`},
    body:JSON.stringify(payload)
  });
  const text=await r.text();
  let data=null;
  try{data=text?JSON.parse(text):null}catch{data=text}
  if(!r.ok){
    const msg=data?.message||data?.hint||String(data||`HTTP ${r.status}`);
    const err=new Error(msg); err.status=r.status; err.data=data; throw err;
  }
  return data;
}

function normalizeCatalog(raw){
  CATALOG=raw;
  SERVICES=(raw?.services||[]).map(s=>({
    id:s.id,slug:s.slug,name:s.name,price:s.price_cents/100,priceCents:s.price_cents,
    duration:s.duration_min,durationLabel:s.duration_label||`${s.duration_min} min`,
    image:s.image_path?`./${s.image_path}`:'',addons:(s.addons||[]).map(a=>({
      id:a.service_id,slug:a.slug,name:a.name,price:a.price_cents/100,priceCents:a.price_cents,
      duration:a.duration_min,durationLabel:`${a.duration_min} min`,image:a.image_path?`./${a.image_path}`:''
    }))
  }));
  PROFESSIONALS=(raw?.professionals||[]).map(p=>({id:p.id,slug:p.slug,name:p.name,image:p.image_path?`./${p.image_path}`:''}));
}

const serviceById=id=>SERVICES.find(s=>s.id===id);
const proById=id=>PROFESSIONALS.find(p=>p.id===id);
const selectedAddons=()=>{
  const s=serviceById(state.booking.serviceId);
  return (state.booking.addons||[]).map(id=>s?.addons.find(a=>a.id===id)).filter(Boolean);
};
const selectedPrice=()=> (serviceById(state.booking.serviceId)?.price||0)+selectedAddons().reduce((x,a)=>x+a.price,0);
const selectedDuration=()=> (serviceById(state.booking.serviceId)?.duration||0)+selectedAddons().reduce((x,a)=>x+a.duration,0);

function localDateISO(d){return `${d.getFullYear()}-${pad(d.getMonth()+1)}-${pad(d.getDate())}`}
function parseLocalDate(iso){return new Date(`${iso}T12:00:00`)}
function humanDate(iso,long=true){return new Intl.DateTimeFormat('pt-BR',long?{weekday:'long',day:'2-digit',month:'long'}:{day:'2-digit',month:'short'}).format(parseLocalDate(iso))}
function isToday(iso){return iso===localDateISO(new Date())}
function formatPhone(v=''){
  const digits=String(v).replace(/\D/g,'').replace(/^55(?=\d{10,11}$)/,'').slice(0,11);
  if(digits.length<=2)return digits;
  if(digits.length<=7)return `(${digits.slice(0,2)}) ${digits.slice(2)}`;
  return `(${digits.slice(0,2)}) ${digits.slice(2,7)}-${digits.slice(7)}`;
}
function partsInSaoPaulo(iso){
  const parts=Object.fromEntries(new Intl.DateTimeFormat('en-CA',{timeZone:'America/Sao_Paulo',year:'numeric',month:'2-digit',day:'2-digit',hour:'2-digit',minute:'2-digit',hourCycle:'h23'}).formatToParts(new Date(iso)).filter(p=>p.type!=='literal').map(p=>[p.type,p.value]));
  return {date:`${parts.year}-${parts.month}-${parts.day}`,time:`${parts.hour}:${parts.minute}`};
}
function toast(msg){const el=$('#toast');el.textContent=msg;el.classList.add('show');clearTimeout(toast.t);toast.t=setTimeout(()=>el.classList.remove('show'),2600)}
function friendlyError(err){
  const m=String(err?.message||err);
  if(m.includes('SLOT_UNAVAILABLE'))return 'Esse horário acabou de ficar indisponível. Escolha outro.';
  if(m.includes('CANCELLATION_WINDOW_CLOSED'))return 'O prazo para cancelar este horário foi encerrado.';
  if(m.includes('RESCHEDULE_WINDOW_CLOSED'))return 'O prazo para reagendar este horário foi encerrado.';
  if(m.includes('INVALID_PHONE'))return 'Confira o número de WhatsApp.';
  if(m.includes('INVALID_TOKEN'))return 'Este aparelho perdeu o acesso ao seu perfil. A recuperação por WhatsApp será ativada em seguida.';
  return 'Não foi possível concluir agora. Tente novamente.';
}

function currentProfile(){
  const s=getSession();
  return s?.customer?{id:s.customer.id,name:s.customer.full_name||s.customer.name,phone:s.customer.phone_e164||s.customer.phone,birthday:s.customer.birthday||''}:null;
}

function appointmentFromPortal(a){
  const pt=partsInSaoPaulo(a.starts_at);
  return {
    id:a.id,status:a.status,date:pt.date,time:pt.time,serviceId:a.service.id,professionalId:a.professional.id,
    totalPriceCents:a.total_price_cents,addons:(a.addons||[]).map(x=>x.service_id),
    rawAddons:a.addons||[],service:a.service,professional:a.professional,startsAt:a.starts_at,endsAt:a.ends_at
  };
}
function allBookings(){return portalAppointments.map(appointmentFromPortal)}
function futureBookings(){const now=Date.now();return allBookings().filter(b=>b.status==='confirmed'&&new Date(b.startsAt).getTime()>=now).sort((a,b)=>new Date(a.startsAt)-new Date(b.startsAt))}
function pastBookings(){const now=Date.now();return allBookings().filter(b=>b.status!=='cancelled'&&new Date(b.startsAt).getTime()<now).sort((a,b)=>new Date(b.startsAt)-new Date(a.startsAt))}
function bookingServiceLabel(b){
  const base=serviceById(b.serviceId)?.name||b.service?.name||'';
  const adds=(b.rawAddons||[]).map(a=>a.name);
  return adds.length?`${base} + ${adds.join(' + ')}`:base;
}
function bookingDuration(b){
  const base=serviceById(b.serviceId)?.duration||0;
  return base+(b.rawAddons||[]).reduce((s,a)=>s+(a.duration_min||0),0);
}
function bookingPrice(b){return (b.totalPriceCents||0)/100}

async function loadCatalog(){normalizeCatalog(await rpc('barberium_get_catalog',{p_barbershop_slug:SHOP_SLUG,p_unit_slug:UNIT_SLUG}))}
async function refreshPortal(){
  const s=getSession();
  if(!s?.access_token){portalAppointments=[];return}
  try{
    const data=await rpc('barberium_get_customer_portal',{p_barbershop_slug:SHOP_SLUG,p_access_token:s.access_token});
    if(!data?.customer){clearSession();portalAppointments=[];return}
    saveSession({...s,customer:data.customer}); portalAppointments=data.appointments||[];
  }catch(e){console.error(e);portalAppointments=[]}
}

function navigate(view){
  if(view==='booking'){startBooking();return}
  state.view=view; $$('.view').forEach(v=>v.classList.toggle('active',v.dataset.view===view)); $$('.nav-item').forEach(b=>b.classList.toggle('active',b.dataset.nav===view));
  if(view==='home')renderHome(); if(view==='appointments')renderAppointments(); if(view==='profile')renderProfile(); window.scrollTo({top:0,behavior:'smooth'});
}
function showView(view){state.view=view;$$('.view').forEach(v=>v.classList.toggle('active',v.dataset.view===view));$$('.nav-item').forEach(b=>b.classList.toggle('active',b.dataset.nav===view));window.scrollTo({top:0,behavior:'smooth'})}

function renderHome(){
  const p=currentProfile(); $('#profileInitial').textContent=p?p.name.split(/\s+/).slice(0,2).map(x=>x[0]).join('').toUpperCase():'SB';
  $('#heroWelcome').textContent=p?`Olá, ${p.name.split(' ')[0]}. Que bom ter você por aqui.`:'';
  const wrap=$('#nextAppointmentWrap'); const next=futureBookings()[0];
  if(next){
    const pro=proById(next.professionalId)||{name:next.professional?.name||''};
    wrap.innerHTML=`<section class="next-card ${isToday(next.date)?'today':''}"><div class="next-head"><div><span class="kicker">${isToday(next.date)?'Seu horário é hoje':'Seu próximo horário'}</span><h3>${bookingServiceLabel(next)}</h3></div><span class="next-badge">${next.time}</span></div><div class="next-details"><div class="detail-box"><small>Data</small><strong>${humanDate(next.date,false)}</strong></div><div class="detail-box"><small>Profissional</small><strong>${pro.name}</strong></div><div class="detail-box"><small>Duração</small><strong>${bookingDuration(next)} min</strong></div><div class="detail-box"><small>Valor</small><strong>${money(bookingPrice(next))}</strong></div></div><div class="card-actions"><button class="secondary-button" type="button" data-home-reschedule="${next.id}">Reagendar</button><button class="danger-button" type="button" data-home-cancel="${next.id}">Cancelar</button></div></section>`;
    $('[data-home-reschedule]',wrap).onclick=()=>startReschedule(next.id); $('[data-home-cancel]',wrap).onclick=()=>askCancel(next.id);
  }else if(p){
    wrap.innerHTML=`<section class="welcome-back"><span class="kicker">Bem-vindo de volta</span><h3>Que bom ter você aqui, ${p.name.split(' ')[0]}.</h3><p>Você não tem horários futuros. Quando quiser, escolha um novo atendimento.</p><button class="gold-button" type="button" data-action="start-booking">Agendar novo horário →</button></section>`;
  }else wrap.innerHTML='';
  $$('[data-action="start-booking"]').forEach(btn=>btn.onclick=()=>startBooking());
}

function resetBooking(){state.bookingStep=1;state.bookingMode='new';state.editingBookingId=null;state.booking={serviceId:null,addons:[],professionalId:null,date:null,time:null,customer:currentProfile()}}
function startBooking(){resetBooking();showView('booking');renderBooking()}
function startReschedule(id){const b=allBookings().find(x=>x.id===id);if(!b)return;state.bookingMode='reschedule';state.editingBookingId=id;state.booking={serviceId:b.serviceId,addons:[...b.addons],professionalId:b.professionalId,date:b.date,time:b.time,customer:currentProfile()};state.bookingStep=1;showView('booking');renderBooking()}
function startRepeat(id){const b=allBookings().find(x=>x.id===id);if(!b)return;resetBooking();state.booking.serviceId=b.serviceId;state.booking.addons=[...b.addons];state.booking.professionalId=b.professionalId;showView('booking');renderBooking()}

const STEP_TITLES={1:'Escolha o serviço',2:'Escolha o profissional',3:'Escolha o dia',4:'Escolha o horário',5:'Seus dados',6:'Revise e confirme'};
function renderBooking(){const s=state.bookingStep;$('#bookingModeLabel').textContent=state.bookingMode==='reschedule'?'Reagendar horário':'Novo agendamento';$('#bookingStepTitle').textContent=STEP_TITLES[s]||'Horário confirmado';$('#stepCounter').textContent=s<=6?`${s}/6`:'';$('#bookingProgress').style.width=`${Math.min(s,6)/6*100}%`;$('#bookingBack').style.visibility=s===7?'hidden':'visible';if(s===1)bookingServices();else if(s===2)bookingProfessionals();else if(s===3)bookingDates();else if(s===4)bookingTimes();else if(s===5)bookingCustomer();else if(s===6)bookingReview();else bookingConfirmation()}
function stepNext(){state.bookingStep=Math.min(7,state.bookingStep+1);renderBooking();window.scrollTo({top:0,behavior:'smooth'})}
function stepBack(){if(state.bookingStep<=1){navigate('home');return}state.bookingStep--;renderBooking();window.scrollTo({top:0,behavior:'smooth'})}

function bookingServices(){
  const stage=$('#bookingStage'),service=serviceById(state.booking.serviceId),suggestions=service?.addons||[];
  const addonHTML=service&&suggestions.length?`<section class="addon-section"><div class="addon-heading"><span class="kicker">Complete seu atendimento</span><h3>Que tal adicionar?</h3><p>Opcional. Você pode continuar sem nenhum adicional.</p></div><div class="addon-list">${suggestions.map(a=>{const selected=state.booking.addons.includes(a.id);const regular=serviceById(a.id)?.price||a.price;return `<button class="addon-card ${selected?'selected':''}" type="button" data-addon="${a.id}"><img src="${a.image}" alt="${a.name}"><span class="addon-info"><strong>${a.name}</strong><small>${a.durationLabel}</small><span class="addon-price">${a.price<regular?`<del>${money(regular)}</del> `:''}<b>+ ${money(a.price)}</b></span></span><span class="addon-action">${selected?'✓':'+'}</span></button>`}).join('')}</div></section>`:'';
  stage.innerHTML=`<div class="booking-list">${SERVICES.map(s=>`<button class="choice-service ${state.booking.serviceId===s.id?'selected':''}" type="button" data-service="${s.id}"><img src="${s.image}" alt=""><span><h3>${s.name}</h3><p><strong>${money(s.price)}</strong> · ${s.durationLabel}</p></span><span class="radio-mark"></span></button>`).join('')}</div>${addonHTML}${state.booking.serviceId?`<div class="booking-total-mini"><span>Total selecionado</span><strong>${money(selectedPrice())}</strong></div><button class="gold-button continue-btn" id="serviceNext" type="button">Continuar →</button>`:''}`;
  $$('[data-service]',stage).forEach(b=>b.onclick=()=>{if(state.booking.serviceId!==b.dataset.service)state.booking.addons=[];state.booking.serviceId=b.dataset.service;state.booking.date=null;state.booking.time=null;bookingServices()});
  $$('[data-addon]',stage).forEach(b=>b.onclick=()=>{const set=new Set(state.booking.addons);set.has(b.dataset.addon)?set.delete(b.dataset.addon):set.add(b.dataset.addon);state.booking.addons=[...set];state.booking.date=null;state.booking.time=null;bookingServices()});
  $('#serviceNext')?.addEventListener('click',stepNext);
}
function bookingProfessionals(){const stage=$('#bookingStage');stage.innerHTML=`<div class="booking-list">${PROFESSIONALS.map(p=>`<button class="pro-choice ${state.booking.professionalId===p.id?'selected':''}" type="button" data-pro="${p.id}" data-pro-slug="${p.slug}"><img src="${p.image}" alt="${p.name}"><strong>${p.name}</strong><span class="radio-mark"></span></button>`).join('')}</div>${state.booking.professionalId?'<button class="gold-button continue-btn" id="proNext" type="button">Continuar →</button>':''}`;$$('[data-pro]',stage).forEach(b=>b.onclick=()=>{state.booking.professionalId=b.dataset.pro;state.booking.date=null;state.booking.time=null;bookingProfessionals()});$('#proNext')?.addEventListener('click',stepNext)}
function availableDates(){const days=Number(CATALOG?.unit?.settings?.days_ahead??30),closed=[0],arr=[],today=new Date();for(let i=0;i<=days;i++){const d=new Date(today);d.setHours(12,0,0,0);d.setDate(today.getDate()+i);if(closed.includes(d.getDay()))continue;arr.push(d)}return arr}
function bookingDates(){const stage=$('#bookingStage'),dates=availableDates(),monthFmt=new Intl.DateTimeFormat('pt-BR',{month:'long',year:'numeric'});stage.innerHTML=`<p class="month-label">${monthFmt.format(dates[0])}</p><div class="calendar-strip">${dates.slice(0,16).map(d=>{const iso=localDateISO(d),wd=new Intl.DateTimeFormat('pt-BR',{weekday:'short'}).format(d).replace('.',''),mon=new Intl.DateTimeFormat('pt-BR',{month:'short'}).format(d).replace('.','');return `<button class="day-button ${state.booking.date===iso?'selected':''}" type="button" data-date="${iso}"><small>${wd}</small><strong>${pad(d.getDate())}</strong><span>${mon}</span></button>`}).join('')}</div>${state.booking.date?'<button class="gold-button continue-btn" id="dateNext" type="button">Ver horários →</button>':''}`;$$('[data-date]',stage).forEach(b=>b.onclick=()=>{state.booking.date=b.dataset.date;state.booking.time=null;bookingDates()});$('#dateNext')?.addEventListener('click',stepNext)}
async function bookingTimes(){
  const stage=$('#bookingStage');stage.innerHTML=`<p class="month-label">${humanDate(state.booking.date)}</p><div class="no-times">Carregando horários disponíveis…</div>`;
  try{
    const times=await rpc('barberium_get_available_slots',{p_barbershop_slug:SHOP_SLUG,p_unit_slug:UNIT_SLUG,p_professional_id:state.booking.professionalId,p_service_id:state.booking.serviceId,p_addon_service_ids:state.booking.addons,p_date:state.booking.date});
    stage.innerHTML=`<p class="month-label">${humanDate(state.booking.date)}</p>${times?.length?`<div class="time-grid">${times.map(t=>`<button class="time-btn ${state.booking.time===t?'selected':''}" type="button" data-time="${t}">${t}</button>`).join('')}</div>`:`<div class="no-times">Não há horários disponíveis neste dia para esse serviço e profissional. Volte e escolha outro dia.</div>`}${state.booking.time?'<button class="gold-button continue-btn" id="timeNext" type="button">Continuar →</button>':''}`;
    $$('[data-time]',stage).forEach(b=>b.onclick=()=>{state.booking.time=b.dataset.time;bookingTimes()});$('#timeNext')?.addEventListener('click',stepNext);
  }catch(e){console.error(e);stage.innerHTML='<div class="no-times">Não foi possível consultar a agenda agora. Tente novamente.</div>'}
}
function bookingCustomer(){
  const stage=$('#bookingStage'),p=currentProfile();
  if(p){state.booking.customer=p;stage.innerHTML=`<div class="known-client"><span class="kicker">Dados reconhecidos neste aparelho</span><h3>Olá, ${p.name.split(' ')[0]}.</h3><p>Você não precisa preencher seus dados novamente.</p><div class="known-row"><span>Nome</span><strong>${p.name}</strong></div><div class="known-row"><span>WhatsApp</span><strong>${formatPhone(p.phone)}</strong></div><div class="known-row"><span>Aniversário</span><strong>${p.birthday||'Não informado'}</strong></div><button class="text-button" id="editProfileFromBooking" type="button">Editar meus dados</button></div><button class="gold-button continue-btn" id="customerNext" type="button">Continuar →</button>`;$('#customerNext').onclick=stepNext;$('#editProfileFromBooking').onclick=()=>navigate('profile');return}
  stage.innerHTML=`<form class="form-grid" id="customerForm"><div class="field"><label for="fullName">Nome e sobrenome</label><input id="fullName" name="name" autocomplete="name" required placeholder="Seu nome completo"></div><div class="field"><label for="phone">Número de WhatsApp</label><input id="phone" name="phone" inputmode="tel" autocomplete="tel" required placeholder="(11) 99999-9999"></div><div class="field"><label for="birthday">Data de aniversário <span style="text-transform:none;font-weight:500">(opcional)</span></label><input id="birthday" name="birthday" type="date"><p class="field-hint">Opcional — para lembrarmos de você em datas especiais.</p></div><button class="gold-button continue-btn" type="submit">Continuar →</button></form>`;
  $('#phone').oninput=e=>e.target.value=formatPhone(e.target.value);$('#customerForm').onsubmit=e=>{e.preventDefault();const fd=new FormData(e.currentTarget),phone=String(fd.get('phone')).replace(/\D/g,''),name=String(fd.get('name')).trim();if(name.split(/\s+/).length<2){toast('Informe nome e sobrenome.');return}if(phone.length<10){toast('Informe um WhatsApp válido.');return}state.booking.customer={name,phone,birthday:String(fd.get('birthday')||'')};stepNext()}
}
function bookingReview(){const stage=$('#bookingStage'),s=serviceById(state.booking.serviceId),p=proById(state.booking.professionalId),c=state.booking.customer;stage.innerHTML=`<div class="review-card"><div class="review-hero"><img src="${s.image}" alt=""><div><h3>${s.name}</h3><p>${money(selectedPrice())}</p></div></div><div class="review-lines"><div class="review-line"><span>Profissional</span><strong>${p.name}</strong></div><div class="review-line"><span>Data</span><strong>${humanDate(state.booking.date)}</strong></div><div class="review-line"><span>Horário</span><strong>${state.booking.time}</strong></div>${selectedAddons().map(a=>`<div class="review-line"><span>Adicional</span><strong>${a.name} · + ${money(a.price)}</strong></div>`).join('')}<div class="review-line"><span>Duração total</span><strong>${selectedDuration()} min</strong></div><div class="review-line"><span>Total</span><strong>${money(selectedPrice())}</strong></div><div class="review-line"><span>Cliente</span><strong>${c.name}</strong></div></div></div><div class="stage-actions"><button class="secondary-button" id="reviewBack" type="button">Voltar e alterar</button><button class="gold-button" id="confirmBooking" type="button">${state.bookingMode==='reschedule'?'Confirmar novo horário':'Confirmar agendamento'}</button></div>`;$('#reviewBack').onclick=()=>{state.bookingStep=1;renderBooking()};$('#confirmBooking').onclick=commitBooking}
async function commitBooking(){
  const btn=$('#confirmBooking');if(btn){btn.disabled=true;btn.textContent='Confirmando…'}
  try{
    const session=getSession();
    if(state.bookingMode==='reschedule'){
      await rpc('barberium_reschedule_appointment',{p_barbershop_slug:SHOP_SLUG,p_unit_slug:UNIT_SLUG,p_access_token:session?.access_token||'',p_appointment_id:state.editingBookingId,p_professional_id:state.booking.professionalId,p_service_id:state.booking.serviceId,p_addon_service_ids:state.booking.addons,p_date:state.booking.date,p_time:state.booking.time});
    }else{
      const c=state.booking.customer;
      const res=await rpc('barberium_create_appointment',{p_barbershop_slug:SHOP_SLUG,p_unit_slug:UNIT_SLUG,p_professional_id:state.booking.professionalId,p_service_id:state.booking.serviceId,p_addon_service_ids:state.booking.addons,p_date:state.booking.date,p_time:state.booking.time,p_full_name:c.name,p_phone:c.phone,p_birthday:c.birthday||null,p_existing_token:session?.access_token||null});
      if(res?.access_token){saveSession({access_token:res.access_token,customer:{id:res.customer_id,full_name:c.name,phone_e164:c.phone,birthday:c.birthday||null}})}
    }
    await refreshPortal();state.bookingStep=7;renderBooking();renderHome();
  }catch(e){console.error(e);toast(friendlyError(e));if(btn){btn.disabled=false;btn.textContent=state.bookingMode==='reschedule'?'Confirmar novo horário':'Confirmar agendamento'}}
}
function bookingConfirmation(){const stage=$('#bookingStage'),s=serviceById(state.booking.serviceId),p=proById(state.booking.professionalId);stage.innerHTML=`<div class="confirmation"><div class="confirm-seal">✓</div><h2>Horário confirmado.</h2><p>Esperamos você na Scalabrini Barbieri — II Unidade, Bragança Paulista.</p><div class="review-card"><div class="review-hero"><img src="${s.image}" alt=""><div><h3>${s.name}</h3><p>${money(selectedPrice())}</p></div></div><div class="review-lines"><div class="review-line"><span>Profissional</span><strong>${p.name}</strong></div><div class="review-line"><span>Data</span><strong>${humanDate(state.booking.date)}</strong></div><div class="review-line"><span>Horário</span><strong>${state.booking.time}</strong></div>${selectedAddons().map(a=>`<div class="review-line"><span>Adicional</span><strong>${a.name}</strong></div>`).join('')}</div></div><div class="stage-actions"><button class="secondary-button" id="confirmHome" type="button">Voltar ao início</button><button class="gold-button" id="confirmAppts" type="button">Ver meu agendamento</button></div></div>`;$('#confirmHome').onclick=()=>navigate('home');$('#confirmAppts').onclick=()=>navigate('appointments')}

function renderAppointments(){
  const root=$('#appointmentsContent');$$('.tab').forEach(t=>t.classList.toggle('active',t.dataset.tab===state.appointmentsTab));const list=state.appointmentsTab==='upcoming'?futureBookings():pastBookings();
  if(!currentProfile()){root.innerHTML=`<div class="empty-state"><h3>Seus horários aparecerão aqui.</h3><p>Depois do primeiro agendamento neste aparelho, o Barberium reconhece você automaticamente.</p><button class="gold-button" id="emptyBook" type="button">Agendar agora →</button></div>`;$('#emptyBook').onclick=()=>startBooking();return}
  if(!list.length){root.innerHTML=`<div class="empty-state"><h3>${state.appointmentsTab==='upcoming'?'Você não tem horários agendados.':'Seu histórico ainda está vazio.'}</h3><p>${state.appointmentsTab==='upcoming'?'Quando quiser, escolha seu próximo atendimento.':'Seus atendimentos anteriores aparecerão aqui.'}</p>${state.appointmentsTab==='upcoming'?'<button class="gold-button" id="emptyBook" type="button">Agendar agora →</button>':''}</div>`;$('#emptyBook')?.addEventListener('click',()=>startBooking());return}
  root.innerHTML=list.map((b,i)=>{const p=proById(b.professionalId)||{name:b.professional?.name||'',image:b.professional?.image_path?`./${b.professional.image_path}`:''},up=state.appointmentsTab==='upcoming';return `<article class="appointment-card ${up&&i===0?'featured':''}"><div class="appt-top"><div><h3>${bookingServiceLabel(b)}</h3><p>${humanDate(b.date)} • ${b.time} • ${bookingDuration(b)} min</p></div><span class="appt-price">${money(bookingPrice(b))}</span></div><div class="appt-pro"><img src="${p.image}" alt=""><strong>${p.name}</strong></div><div class="appt-actions">${up?`<button class="secondary-button" type="button" data-reschedule="${b.id}">Reagendar</button><button class="danger-button" type="button" data-cancel="${b.id}">Cancelar</button>`:`<button class="secondary-button" type="button" data-repeat="${b.id}">Agendar novamente</button>`}</div></article>`}).join('');
  $$('[data-reschedule]',root).forEach(b=>b.onclick=()=>startReschedule(b.dataset.reschedule));$$('[data-cancel]',root).forEach(b=>b.onclick=()=>askCancel(b.dataset.cancel));$$('[data-repeat]',root).forEach(b=>b.onclick=()=>startRepeat(b.dataset.repeat));
}
function askCancel(id){const b=allBookings().find(x=>x.id===id);if(!b)return;modal(`<h3>Cancelar agendamento?</h3><p>Você está prestes a cancelar <strong>${bookingServiceLabel(b)}</strong>, ${humanDate(b.date)} às ${b.time}.</p><div class="modal-actions"><button class="secondary-button" data-modal-close type="button">Manter agendamento</button><button class="danger-button" id="confirmCancel" type="button">Sim, cancelar</button></div>`);$('#confirmCancel').onclick=async()=>{try{await rpc('barberium_cancel_appointment',{p_barbershop_slug:SHOP_SLUG,p_access_token:getSession()?.access_token||'',p_appointment_id:id});await refreshPortal();closeModal();toast('Agendamento cancelado.');renderAppointments();renderHome()}catch(e){toast(friendlyError(e))}}}

function renderProfile(){
  const root=$('#profileContent'),p=currentProfile();$('#profileInitial').textContent=p?p.name.split(/\s+/).slice(0,2).map(x=>x[0]).join('').toUpperCase():'SB';
  if(!p){$('#profileGreeting').textContent='Meu perfil';root.innerHTML=`<div class="empty-state"><h3>Você ainda não tem dados salvos.</h3><p>Seu perfil é criado automaticamente depois do primeiro agendamento. Sem login e sem senha.</p><button class="gold-button" id="profileBook" type="button">Fazer meu primeiro agendamento →</button></div><section class="profile-section"><h3>Acesso em outro aparelho</h3><p>Quando ativarmos a recuperação via WhatsApp, você poderá validar seu número no novo aparelho e recuperar seu histórico.</p></section>`;$('#profileBook').onclick=()=>startBooking();return}
  $('#profileGreeting').textContent=`Olá, ${p.name.split(' ')[0]}.`;root.innerHTML=`<div class="profile-card"><div class="profile-row"><small>Nome e sobrenome</small><strong>${p.name}</strong></div><div class="profile-row"><small>WhatsApp</small><strong>${formatPhone(p.phone)}</strong></div><div class="profile-row"><small>Data de aniversário</small><strong>${p.birthday||'Não informado'}</strong></div></div><div class="profile-actions"><button class="secondary-button" id="editProfile" type="button">Editar meus dados</button><button class="secondary-button" id="otherDevice" type="button">Acessar em outro aparelho</button></div><section class="profile-section"><h3>Privacidade dos meus dados</h3><p>Nome, telefone, aniversário e histórico são utilizados para seus agendamentos e relacionamento com a Scalabrini Barbieri.</p><button class="danger-button" id="deleteData" type="button">Solicitar exclusão dos meus dados</button></section>`;
  $('#editProfile').onclick=editProfileModal;$('#otherDevice').onclick=()=>modal(`<h3>Acesso em outro aparelho</h3><p>A recuperação por código no WhatsApp é a próxima integração do Barberium. Você não precisará criar senha.</p><div class="modal-actions"><button class="gold-button" data-modal-close type="button">Entendi</button></div>`);$('#deleteData').onclick=()=>modal(`<h3>Solicitar exclusão</h3><p>Para proteger seu histórico, a exclusão dos dados precisa ser confirmada pela barbearia. Fale conosco pelo WhatsApp para solicitar a remoção.</p><div class="modal-actions"><a class="gold-button" style="text-decoration:none" href="https://wa.me/5511945246544" target="_blank" rel="noopener">Abrir WhatsApp</a><button class="secondary-button" data-modal-close type="button">Voltar</button></div>`)
}
function editProfileModal(){const p=currentProfile();modal(`<h3>Editar meus dados</h3><form class="form-grid" id="profileEditForm"><div class="field"><label>Nome e sobrenome</label><input name="name" required value="${p.name.replace(/"/g,'&quot;')}"></div><div class="field"><label>Data de aniversário <span style="text-transform:none">(opcional)</span></label><input type="date" name="birthday" value="${p.birthday||''}"></div><div class="field"><label>WhatsApp</label><input value="${formatPhone(p.phone)}" disabled><p class="field-hint">A alteração de número exigirá confirmação no novo WhatsApp.</p></div><div class="modal-actions"><button class="secondary-button" data-modal-close type="button">Cancelar</button><button class="gold-button" type="submit">Salvar</button></div></form>`);$('#profileEditForm').onsubmit=async e=>{e.preventDefault();const fd=new FormData(e.currentTarget);try{const customer=await rpc('barberium_update_customer_profile',{p_barbershop_slug:SHOP_SLUG,p_access_token:getSession().access_token,p_full_name:String(fd.get('name')).trim(),p_birthday:String(fd.get('birthday')||'')||null});saveSession({...getSession(),customer});closeModal();toast('Dados atualizados.');renderProfile();renderHome()}catch(err){toast(friendlyError(err))}}}
function modal(html){$('#modalBox').innerHTML=html;$('#modalBackdrop').classList.add('open');$('#modalBackdrop').setAttribute('aria-hidden','false');$$('[data-modal-close]',$('#modalBox')).forEach(b=>b.onclick=closeModal)}
function closeModal(){$('#modalBackdrop').classList.remove('open');$('#modalBackdrop').setAttribute('aria-hidden','true')}

async function init(){
  try{await loadCatalog();await refreshPortal();renderHome();renderAppointments();renderProfile()}
  catch(e){console.error(e);toast('Não foi possível conectar ao Barberium. Atualize a página.')}
}

$$('[data-nav]').forEach(b=>b.onclick=()=>navigate(b.dataset.nav));$$('[data-action="start-booking"]').forEach(b=>b.onclick=()=>startBooking());$('#bookingBack').onclick=stepBack;$$('.tab').forEach(t=>t.onclick=()=>{state.appointmentsTab=t.dataset.tab;renderAppointments()});$('#modalBackdrop').onclick=e=>{if(e.target===e.currentTarget)closeModal()};document.addEventListener('keydown',e=>{if(e.key==='Escape')closeModal()});
init();
if('serviceWorker'in navigator)window.addEventListener('load',()=>navigator.serviceWorker.register('./sw.js?v=7',{updateViaCache:'none'}).catch(()=>{}));
