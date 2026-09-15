const SERVICES = [
  {id:'corte', name:'Corte', price:90, durationLabel:'30–40 min', duration:40, image:'./assets/corte.webp'},
  {id:'barba-tradizionale', name:'Barba Tradizionale', price:75, durationLabel:'35–45 min', duration:45, image:'./assets/barba-tradizionale.webp'},
  {id:'combo-corte-barba', name:'Combo Corte + Barba', price:155, durationLabel:'1h15', duration:75, image:'./assets/combo-corte-barba.webp'},
  {id:'barboterapia', name:'Barboterapia', price:145, durationLabel:'1h', duration:60, image:'./assets/barboterapia.webp'},
  {id:'combo-corte-barboterapia', name:'Combo Corte + Barboterapia', price:215, durationLabel:'1h30', duration:90, image:'./assets/combo-corte-barboterapia.webp'},
  {id:'corte-barba-sobrancelha', name:'Corte + Barba + Sobrancelha', price:175, durationLabel:'1h', duration:60, image:'./assets/corte-barba-sobrancelha.webp'},
  {id:'barba-express', name:'Barba Express', price:60, durationLabel:'20 min', duration:20, image:'./assets/barba-express.webp'},
  {id:'corte-barba-express', name:'Corte + Barba Express', price:140, durationLabel:'40 min', duration:40, image:'./assets/corte-barba-express.webp'},
  {id:'sobrancelha', name:'Sobrancelha', price:20, durationLabel:'10 min', duration:10, image:'./assets/sobrancelha.webp'},
  {id:'pezinho-detalhes', name:'Pezinho Detalhes', price:25, durationLabel:'10 min', duration:10, image:'./assets/pezinho-detalhes.webp'},
  {id:'cabeca-raspada', name:'Cabeça Raspada', price:60, durationLabel:'30–60 min', duration:60, image:'./assets/cabeca-raspada.webp'}
];

const PROFESSIONALS = [
  {id:'vinicius', name:'Vinicius Nunes', image:'./assets/vinicius-nunes.webp'},
  {id:'jean', name:'Jean Dalarmi', image:'./assets/jean-dalarmi.webp'}
];

// These values are temporary defaults for this static client prototype.
// In the full Barberium they come from the admin panel.
const AGENDA_CONFIG = {
  openHour: 10,
  closeHour: 20,
  closedWeekdays: [0],
  slotMinutes: 10,
  daysAhead: 30,
  minAdvanceMinutes: 0,
  mustFinishByClose: true
};

const LS = {
  profile:'barberium_scalabrini_profile',
  bookings:'barberium_scalabrini_bookings'
};

const state = {
  view:'home',
  bookingStep:1,
  bookingMode:'new',
  editingBookingId:null,
  booking:{serviceId:null, professionalId:null, date:null, time:null, customer:null},
  appointmentsTab:'upcoming'
};

const $ = (s, root=document) => root.querySelector(s);
const $$ = (s, root=document) => [...root.querySelectorAll(s)];
const money = n => new Intl.NumberFormat('pt-BR',{style:'currency',currency:'BRL'}).format(n);
const getProfile = () => JSON.parse(localStorage.getItem(LS.profile)||'null');
const saveProfile = p => localStorage.setItem(LS.profile,JSON.stringify(p));
const getBookings = () => JSON.parse(localStorage.getItem(LS.bookings)||'[]');
const saveBookings = b => localStorage.setItem(LS.bookings,JSON.stringify(b));
const serviceById = id => SERVICES.find(s=>s.id===id);
const proById = id => PROFESSIONALS.find(p=>p.id===id);
const pad = n => String(n).padStart(2,'0');

function localDateISO(d){
  return `${d.getFullYear()}-${pad(d.getMonth()+1)}-${pad(d.getDate())}`;
}
function parseLocalDate(iso){ return new Date(`${iso}T12:00:00`); }
function dateTimeOf(b){ return new Date(`${b.date}T${b.time}:00`); }
function humanDate(iso, long=true){
  return new Intl.DateTimeFormat('pt-BR', long
    ? {weekday:'long',day:'2-digit',month:'long'}
    : {day:'2-digit',month:'short'}).format(parseLocalDate(iso));
}
function isToday(iso){ return iso===localDateISO(new Date()); }
function formatPhone(v=''){
  const digits=v.replace(/\D/g,'').slice(0,11);
  if(digits.length<=2) return digits;
  if(digits.length<=7) return `(${digits.slice(0,2)}) ${digits.slice(2)}`;
  return `(${digits.slice(0,2)}) ${digits.slice(2,7)}-${digits.slice(7)}`;
}
function uid(){ return crypto.randomUUID?.() || `${Date.now()}-${Math.random().toString(16).slice(2)}`; }

function toast(msg){
  const el=$('#toast'); el.textContent=msg; el.classList.add('show');
  clearTimeout(toast.t); toast.t=setTimeout(()=>el.classList.remove('show'),2500);
}

function navigate(view){
  if(view==='booking'){
    startBooking();
    return;
  }
  state.view=view;
  $$('.view').forEach(v=>v.classList.toggle('active',v.dataset.view===view));
  $$('.nav-item').forEach(b=>b.classList.toggle('active',b.dataset.nav===view));
  if(view==='home') renderHome();
  if(view==='appointments') renderAppointments();
  if(view==='profile') renderProfile();
  window.scrollTo({top:0,behavior:'smooth'});
}

function showView(view){
  state.view=view;
  $$('.view').forEach(v=>v.classList.toggle('active',v.dataset.view===view));
  $$('.nav-item').forEach(b=>b.classList.toggle('active',b.dataset.nav===view));
  window.scrollTo({top:0,behavior:'smooth'});
}

function futureBookings(){
  const now=new Date();
  return getBookings().filter(b=>b.status!=='cancelled' && dateTimeOf(b)>=now).sort((a,b)=>dateTimeOf(a)-dateTimeOf(b));
}
function pastBookings(){
  const now=new Date();
  return getBookings().filter(b=>b.status!=='cancelled' && dateTimeOf(b)<now).sort((a,b)=>dateTimeOf(b)-dateTimeOf(a));
}

function renderHomeServices(){
  const root=$('#homeServices');
  root.innerHTML=SERVICES.map(s=>`
    <button class="service-home-card" type="button" data-home-service="${s.id}">
      <img src="${s.image}" alt="${s.name}" loading="lazy">
      <span class="service-home-info">
        <strong>${s.name}</strong>
        <span class="service-meta">
          <span class="price">${money(s.price)}</span>
          <span class="duration">${s.durationLabel}</span>
        </span>
      </span>
    </button>`).join('');
  $$('[data-home-service]',root).forEach(btn=>btn.addEventListener('click',()=>{
    startBooking({serviceId:btn.dataset.homeService, step:2});
  }));
}

function renderHome(){
  const profile=getProfile();
  $('#profileInitial').textContent=profile ? profile.name.split(/\s+/).slice(0,2).map(x=>x[0]).join('').toUpperCase() : 'SB';
  $('#heroWelcome').textContent=profile ? `Olá, ${profile.name.split(' ')[0]}. Que bom ter você por aqui.` : '';
  renderHomeServices();

  const wrap=$('#nextAppointmentWrap');
  const next=futureBookings()[0];
  if(next){
    const s=serviceById(next.serviceId), p=proById(next.professionalId);
    wrap.innerHTML=`
      <section class="next-card ${isToday(next.date)?'today':''}">
        <div class="next-head">
          <div><span class="kicker">${isToday(next.date)?'Seu horário é hoje':'Seu próximo horário'}</span><h3>${s.name}</h3></div>
          <span class="next-badge">${next.time}</span>
        </div>
        <div class="next-details">
          <div class="detail-box"><small>Data</small><strong>${humanDate(next.date,false)}</strong></div>
          <div class="detail-box"><small>Profissional</small><strong>${p.name}</strong></div>
          <div class="detail-box"><small>Duração</small><strong>${s.durationLabel}</strong></div>
          <div class="detail-box"><small>Valor</small><strong>${money(s.price)}</strong></div>
        </div>
        <div class="card-actions">
          <button class="secondary-button" type="button" data-home-reschedule="${next.id}">Reagendar</button>
          <button class="danger-button" type="button" data-home-cancel="${next.id}">Cancelar</button>
        </div>
      </section>`;
    $('[data-home-reschedule]',wrap).addEventListener('click',()=>startReschedule(next.id));
    $('[data-home-cancel]',wrap).addEventListener('click',()=>askCancel(next.id));
  } else if(profile){
    wrap.innerHTML=`
      <section class="welcome-back">
        <span class="kicker">Bem-vindo de volta</span>
        <h3>Que bom ter você aqui, ${profile.name.split(' ')[0]}.</h3>
        <p>Você não tem horários futuros. Quando quiser, escolha um novo atendimento.</p>
        <button class="gold-button" type="button" data-action="start-booking">Agendar novo horário →</button>
      </section>`;
    $('[data-action="start-booking"]',wrap).addEventListener('click',()=>startBooking());
  } else {
    wrap.innerHTML='';
  }
}

function resetBooking(){
  state.bookingStep=1; state.bookingMode='new'; state.editingBookingId=null;
  state.booking={serviceId:null,professionalId:null,date:null,time:null,customer:getProfile()};
}
function startBooking(opts={}){
  resetBooking();
  Object.assign(state.booking, opts.serviceId?{serviceId:opts.serviceId}:{});
  state.bookingStep=opts.step||1;
  showView('booking'); renderBooking();
}
function startReschedule(id){
  const b=getBookings().find(x=>x.id===id); if(!b)return;
  state.bookingMode='reschedule'; state.editingBookingId=id;
  state.booking={serviceId:b.serviceId,professionalId:b.professionalId,date:b.date,time:b.time,customer:getProfile()};
  state.bookingStep=1;
  showView('booking'); renderBooking();
}
function startRepeat(id){
  const b=getBookings().find(x=>x.id===id); if(!b)return;
  resetBooking(); state.booking.serviceId=b.serviceId; state.booking.professionalId=b.professionalId; state.bookingStep=1;
  showView('booking'); renderBooking();
}

const STEP_TITLES={1:'Escolha o serviço',2:'Escolha o profissional',3:'Escolha o dia',4:'Escolha o horário',5:'Seus dados',6:'Revise e confirme'};

function renderBooking(){
  const step=state.bookingStep;
  $('#bookingModeLabel').textContent=state.bookingMode==='reschedule'?'Reagendar horário':'Novo agendamento';
  $('#bookingStepTitle').textContent=STEP_TITLES[step]||'Horário confirmado';
  $('#stepCounter').textContent=step<=6?`${step}/6`:'';
  $('#bookingProgress').style.width=`${Math.min(step,6)/6*100}%`;
  $('#bookingBack').style.visibility=step===7?'hidden':'visible';
  if(step===1) bookingServices();
  else if(step===2) bookingProfessionals();
  else if(step===3) bookingDates();
  else if(step===4) bookingTimes();
  else if(step===5) bookingCustomer();
  else if(step===6) bookingReview();
  else bookingConfirmation();
}

function stepNext(){ state.bookingStep=Math.min(7,state.bookingStep+1); renderBooking(); window.scrollTo({top:0,behavior:'smooth'}); }
function stepBack(){
  if(state.bookingStep<=1){ navigate('home'); return; }
  state.bookingStep--; renderBooking(); window.scrollTo({top:0,behavior:'smooth'});
}

function bookingServices(){
  const stage=$('#bookingStage');
  stage.innerHTML=`<div class="booking-list">${SERVICES.map(s=>`
    <button class="choice-service ${state.booking.serviceId===s.id?'selected':''}" type="button" data-service="${s.id}">
      <img src="${s.image}" alt="">
      <span><h3>${s.name}</h3><p><strong>${money(s.price)}</strong> · ${s.durationLabel}</p></span>
      <span class="radio-mark"></span>
    </button>`).join('')}</div>
    ${state.booking.serviceId?'<button class="gold-button continue-btn" id="serviceNext" type="button">Continuar →</button>':''}`;
  $$('[data-service]',stage).forEach(b=>b.addEventListener('click',()=>{
    state.booking.serviceId=b.dataset.service;
    state.booking.date=null; state.booking.time=null;
    bookingServices();
  }));
  $('#serviceNext')?.addEventListener('click',stepNext);
}
function bookingProfessionals(){
  const stage=$('#bookingStage');
  stage.innerHTML=`<div class="booking-list">${PROFESSIONALS.map(p=>`
    <button class="pro-choice ${state.booking.professionalId===p.id?'selected':''}" type="button" data-pro="${p.id}">
      <img src="${p.image}" alt="${p.name}">
      <strong>${p.name}</strong><span class="radio-mark"></span>
    </button>`).join('')}</div>
    ${state.booking.professionalId?'<button class="gold-button continue-btn" id="proNext" type="button">Continuar →</button>':''}`;
  $$('[data-pro]',stage).forEach(b=>b.addEventListener('click',()=>{
    state.booking.professionalId=b.dataset.pro;
    state.booking.date=null; state.booking.time=null;
    bookingProfessionals();
  }));
  $('#proNext')?.addEventListener('click',stepNext);
}
function availableDates(){
  const arr=[], today=new Date();
  for(let i=0;i<=AGENDA_CONFIG.daysAhead;i++){
    const d=new Date(today); d.setHours(12,0,0,0); d.setDate(today.getDate()+i);
    if(AGENDA_CONFIG.closedWeekdays.includes(d.getDay())) continue;
    arr.push(d);
  }
  return arr;
}
function bookingDates(){
  const stage=$('#bookingStage');
  const dates=availableDates();
  const monthFmt=new Intl.DateTimeFormat('pt-BR',{month:'long',year:'numeric'});
  stage.innerHTML=`<p class="month-label">${monthFmt.format(dates[0])}</p>
    <div class="calendar-strip">${dates.slice(0,16).map(d=>{
      const iso=localDateISO(d);
      const wd=new Intl.DateTimeFormat('pt-BR',{weekday:'short'}).format(d).replace('.','');
      const mon=new Intl.DateTimeFormat('pt-BR',{month:'short'}).format(d).replace('.','');
      return `<button class="day-button ${state.booking.date===iso?'selected':''}" type="button" data-date="${iso}">
        <small>${wd}</small><strong>${pad(d.getDate())}</strong><span>${mon}</span>
      </button>`}).join('')}</div>
    ${state.booking.date?'<button class="gold-button continue-btn" id="dateNext" type="button">Ver horários →</button>':''}`;
  $$('[data-date]',stage).forEach(b=>b.addEventListener('click',()=>{
    state.booking.date=b.dataset.date; state.booking.time=null; bookingDates();
  }));
  $('#dateNext')?.addEventListener('click',stepNext);
}
function minutesFromTime(t){ const [h,m]=t.split(':').map(Number); return h*60+m; }
function timeFromMinutes(v){ return `${pad(Math.floor(v/60))}:${pad(v%60)}`; }
function overlaps(start,duration,b){
  const a1=start, a2=start+duration, b1=minutesFromTime(b.time), bs=serviceById(b.serviceId), b2=b1+(bs?.duration||0);
  return a1<b2 && a2>b1;
}
function availableTimes(){
  const service=serviceById(state.booking.serviceId); if(!service||!state.booking.date||!state.booking.professionalId)return[];
  let bookings=getBookings().filter(b=>b.status!=='cancelled' && b.date===state.booking.date && b.professionalId===state.booking.professionalId && b.id!==state.editingBookingId);
  const open=AGENDA_CONFIG.openHour*60, close=AGENDA_CONFIG.closeHour*60, now=new Date();
  const list=[];
  for(let start=open; start<close; start+=AGENDA_CONFIG.slotMinutes){
    if(AGENDA_CONFIG.mustFinishByClose && start+service.duration>close) continue;
    const slotDate=new Date(`${state.booking.date}T${timeFromMinutes(start)}:00`);
    if(slotDate.getTime() < now.getTime()+AGENDA_CONFIG.minAdvanceMinutes*60000) continue;
    if(bookings.some(b=>overlaps(start,service.duration,b))) continue;
    list.push(timeFromMinutes(start));
  }
  return list;
}
function bookingTimes(){
  const stage=$('#bookingStage'), times=availableTimes();
  stage.innerHTML=`<p class="month-label">${humanDate(state.booking.date)}</p>
    ${times.length?`<div class="time-grid">${times.map(t=>`<button class="time-btn ${state.booking.time===t?'selected':''}" type="button" data-time="${t}">${t}</button>`).join('')}</div>`:
    `<div class="no-times">Não há horários disponíveis neste dia para esse serviço e profissional. Volte e escolha outro dia.</div>`}
    ${state.booking.time?'<button class="gold-button continue-btn" id="timeNext" type="button">Continuar →</button>':''}`;
  $$('[data-time]',stage).forEach(b=>b.addEventListener('click',()=>{state.booking.time=b.dataset.time;bookingTimes()}));
  $('#timeNext')?.addEventListener('click',stepNext);
}
function bookingCustomer(){
  const stage=$('#bookingStage'), p=getProfile();
  if(p){
    state.booking.customer=p;
    stage.innerHTML=`<div class="known-client">
      <span class="kicker">Dados reconhecidos neste aparelho</span>
      <h3>Olá, ${p.name.split(' ')[0]}.</h3>
      <p>Você não precisa preencher seus dados novamente.</p>
      <div class="known-row"><span>Nome</span><strong>${p.name}</strong></div>
      <div class="known-row"><span>WhatsApp</span><strong>${formatPhone(p.phone)}</strong></div>
      <div class="known-row"><span>Aniversário</span><strong>${p.birthday||'Não informado'}</strong></div>
      <button class="text-button" id="editProfileFromBooking" type="button">Editar meus dados</button>
    </div>
    <button class="gold-button continue-btn" id="customerNext" type="button">Continuar →</button>`;
    $('#customerNext').addEventListener('click',stepNext);
    $('#editProfileFromBooking').addEventListener('click',()=>navigate('profile'));
    return;
  }
  stage.innerHTML=`<form class="form-grid" id="customerForm">
    <div class="field"><label for="fullName">Nome e sobrenome</label><input id="fullName" name="name" autocomplete="name" required placeholder="Seu nome completo"></div>
    <div class="field"><label for="phone">Número de WhatsApp</label><input id="phone" name="phone" inputmode="tel" autocomplete="tel" required placeholder="(11) 99999-9999"></div>
    <div class="field"><label for="birthday">Data de aniversário <span style="text-transform:none;font-weight:500">(opcional)</span></label><input id="birthday" name="birthday" type="date"><p class="field-hint">Opcional — para lembrarmos de você em datas especiais.</p></div>
    <button class="gold-button continue-btn" type="submit">Continuar →</button>
  </form>`;
  $('#phone').addEventListener('input',e=>e.target.value=formatPhone(e.target.value));
  $('#customerForm').addEventListener('submit',e=>{
    e.preventDefault(); const fd=new FormData(e.currentTarget);
    const phone=String(fd.get('phone')).replace(/\D/g,'');
    const name=String(fd.get('name')).trim();
    if(name.split(/\s+/).length<2){toast('Informe nome e sobrenome.');return}
    if(phone.length<10){toast('Informe um WhatsApp válido.');return}
    state.booking.customer={name,phone,birthday:String(fd.get('birthday')||'')};
    stepNext();
  });
}
function bookingReview(){
  const stage=$('#bookingStage'), s=serviceById(state.booking.serviceId), p=proById(state.booking.professionalId), c=state.booking.customer;
  stage.innerHTML=`<div class="review-card">
    <div class="review-hero"><img src="${s.image}" alt=""><div><h3>${s.name}</h3><p>${money(s.price)}</p></div></div>
    <div class="review-lines">
      <div class="review-line"><span>Profissional</span><strong>${p.name}</strong></div>
      <div class="review-line"><span>Data</span><strong>${humanDate(state.booking.date)}</strong></div>
      <div class="review-line"><span>Horário</span><strong>${state.booking.time}</strong></div>
      <div class="review-line"><span>Duração</span><strong>${s.durationLabel}</strong></div>
      <div class="review-line"><span>Cliente</span><strong>${c.name}</strong></div>
    </div>
  </div>
  <div class="stage-actions">
    <button class="secondary-button" id="reviewBack" type="button">Voltar e alterar</button>
    <button class="gold-button" id="confirmBooking" type="button">${state.bookingMode==='reschedule'?'Confirmar novo horário':'Confirmar agendamento'}</button>
  </div>`;
  $('#reviewBack').addEventListener('click',()=>{state.bookingStep=1;renderBooking()});
  $('#confirmBooking').addEventListener('click',commitBooking);
}
function commitBooking(){
  const profile=getProfile();
  if(!profile) saveProfile(state.booking.customer);
  const bookings=getBookings();
  const payload={
    id:state.bookingMode==='reschedule'?state.editingBookingId:uid(),
    serviceId:state.booking.serviceId,
    professionalId:state.booking.professionalId,
    date:state.booking.date,time:state.booking.time,
    status:'confirmed',createdAt:new Date().toISOString()
  };
  if(state.bookingMode==='reschedule'){
    const idx=bookings.findIndex(b=>b.id===state.editingBookingId);
    if(idx>=0) bookings[idx]=payload; else bookings.push(payload);
  } else bookings.push(payload);
  saveBookings(bookings);
  state.bookingStep=7; renderBooking(); renderHome();
}
function bookingConfirmation(){
  const stage=$('#bookingStage'), s=serviceById(state.booking.serviceId), p=proById(state.booking.professionalId);
  stage.innerHTML=`<div class="confirmation">
    <div class="confirm-seal">✓</div>
    <h2>Horário confirmado.</h2>
    <p>Esperamos você na Scalabrini Barbieri — II Unidade, Bragança Paulista.</p>
    <div class="review-card">
      <div class="review-hero"><img src="${s.image}" alt=""><div><h3>${s.name}</h3><p>${money(s.price)}</p></div></div>
      <div class="review-lines">
        <div class="review-line"><span>Profissional</span><strong>${p.name}</strong></div>
        <div class="review-line"><span>Data</span><strong>${humanDate(state.booking.date)}</strong></div>
        <div class="review-line"><span>Horário</span><strong>${state.booking.time}</strong></div>
      </div>
    </div>
    <div class="stage-actions">
      <button class="secondary-button" id="confirmHome" type="button">Voltar ao início</button>
      <button class="gold-button" id="confirmAppts" type="button">Ver meu agendamento</button>
    </div>
  </div>`;
  $('#confirmHome').addEventListener('click',()=>navigate('home'));
  $('#confirmAppts').addEventListener('click',()=>navigate('appointments'));
}

function renderAppointments(){
  const root=$('#appointmentsContent');
  $$('.tab').forEach(t=>t.classList.toggle('active',t.dataset.tab===state.appointmentsTab));
  const list=state.appointmentsTab==='upcoming'?futureBookings():pastBookings();
  if(!list.length){
    root.innerHTML=`<div class="empty-state"><h3>${state.appointmentsTab==='upcoming'?'Você não tem horários agendados.':'Seu histórico ainda está vazio.'}</h3>
      <p>${state.appointmentsTab==='upcoming'?'Quando quiser, escolha seu próximo atendimento.':'Seus atendimentos concluídos aparecerão aqui.'}</p>
      ${state.appointmentsTab==='upcoming'?'<button class="gold-button" id="emptyBook" type="button">Agendar agora →</button>':''}
    </div>`;
    $('#emptyBook')?.addEventListener('click',()=>startBooking()); return;
  }
  root.innerHTML=list.map((b,i)=>{
    const s=serviceById(b.serviceId),p=proById(b.professionalId), upcoming=state.appointmentsTab==='upcoming';
    return `<article class="appointment-card ${upcoming&&i===0?'featured':''}">
      <div class="appt-top"><div><h3>${s.name}</h3><p>${humanDate(b.date)} • ${b.time} • ${s.durationLabel}</p></div><span class="appt-price">${money(s.price)}</span></div>
      <div class="appt-pro"><img src="${p.image}" alt=""><strong>${p.name}</strong></div>
      <div class="appt-actions">
        ${upcoming?`<button class="secondary-button" type="button" data-reschedule="${b.id}">Reagendar</button><button class="danger-button" type="button" data-cancel="${b.id}">Cancelar</button>`:
        `<button class="secondary-button" type="button" data-repeat="${b.id}">Agendar novamente</button>`}
      </div>
    </article>`;
  }).join('');
  $$('[data-reschedule]',root).forEach(b=>b.addEventListener('click',()=>startReschedule(b.dataset.reschedule)));
  $$('[data-cancel]',root).forEach(b=>b.addEventListener('click',()=>askCancel(b.dataset.cancel)));
  $$('[data-repeat]',root).forEach(b=>b.addEventListener('click',()=>startRepeat(b.dataset.repeat)));
}
function askCancel(id){
  const b=getBookings().find(x=>x.id===id); if(!b)return;
  const s=serviceById(b.serviceId);
  modal(`<h3>Cancelar agendamento?</h3><p>Você está prestes a cancelar <strong>${s.name}</strong>, ${humanDate(b.date)} às ${b.time}.</p>
    <div class="modal-actions"><button class="secondary-button" data-modal-close type="button">Manter agendamento</button><button class="danger-button" id="confirmCancel" type="button">Sim, cancelar</button></div>`);
  $('#confirmCancel').addEventListener('click',()=>{
    const list=getBookings(); const idx=list.findIndex(x=>x.id===id); if(idx>=0) list[idx].status='cancelled'; saveBookings(list);
    closeModal(); toast('Agendamento cancelado.'); renderAppointments(); renderHome();
  });
}

function renderProfile(){
  const root=$('#profileContent'),p=getProfile();
  $('#profileInitial').textContent=p ? p.name.split(/\s+/).slice(0,2).map(x=>x[0]).join('').toUpperCase() : 'SB';
  if(!p){
    $('#profileGreeting').textContent='Meu perfil';
    root.innerHTML=`<div class="empty-state"><h3>Você ainda não tem dados salvos.</h3><p>Seu perfil é criado automaticamente depois do primeiro agendamento. Sem login e sem senha.</p><button class="gold-button" id="profileBook" type="button">Fazer meu primeiro agendamento →</button></div>
    <section class="profile-section"><h3>Acesso em outro aparelho</h3><p>Quando o Barberium estiver conectado ao WhatsApp da barbearia, você poderá recuperar seus dados informando seu número e confirmando um código recebido pelo WhatsApp.</p></section>`;
    $('#profileBook').addEventListener('click',()=>startBooking()); return;
  }
  $('#profileGreeting').textContent=`Olá, ${p.name.split(' ')[0]}.`;
  root.innerHTML=`<div class="profile-card">
      <div class="profile-row"><small>Nome e sobrenome</small><strong>${p.name}</strong></div>
      <div class="profile-row"><small>WhatsApp</small><strong>${formatPhone(p.phone)}</strong></div>
      <div class="profile-row"><small>Data de aniversário</small><strong>${p.birthday||'Não informado'}</strong></div>
    </div>
    <div class="profile-actions"><button class="secondary-button" id="editProfile" type="button">Editar meus dados</button><button class="secondary-button" id="otherDevice" type="button">Acessar em outro aparelho</button></div>
    <section class="profile-section"><h3>Privacidade dos meus dados</h3><p>Nome, telefone, aniversário e histórico são utilizados para seus agendamentos e relacionamento com a Scalabrini Barbieri.</p><button class="danger-button" id="deleteData" type="button">Solicitar exclusão dos meus dados</button></section>`;
  $('#editProfile').addEventListener('click',editProfileModal);
  $('#otherDevice').addEventListener('click',()=>modal(`<h3>Acesso em outro aparelho</h3><p>No novo aparelho, você informará seu número de WhatsApp e receberá um código para confirmar que o número é seu. Não haverá senha.</p><p class="profile-note">A recuperação real por WhatsApp será ativada quando conectarmos o backend e o provedor de mensagens do Barberium.</p><div class="modal-actions"><button class="gold-button" data-modal-close type="button">Entendi</button></div>`));
  $('#deleteData').addEventListener('click',()=>modal(`<h3>Excluir seus dados?</h3><p>Nesta versão de teste, isso apagará seus dados e agendamentos armazenados neste aparelho.</p><div class="modal-actions"><button class="secondary-button" data-modal-close type="button">Voltar</button><button class="danger-button" id="confirmDeleteData" type="button">Sim, excluir</button></div>`));
  setTimeout(()=>$('#confirmDeleteData')?.addEventListener('click',()=>{localStorage.removeItem(LS.profile);localStorage.removeItem(LS.bookings);closeModal();toast('Dados apagados deste aparelho.');renderProfile();renderHome()}),0);
}
function editProfileModal(){
  const p=getProfile();
  modal(`<h3>Editar meus dados</h3><form class="form-grid" id="profileEditForm">
    <div class="field"><label>Nome e sobrenome</label><input name="name" required value="${p.name.replace(/"/g,'&quot;')}"></div>
    <div class="field"><label>Data de aniversário <span style="text-transform:none">(opcional)</span></label><input type="date" name="birthday" value="${p.birthday||''}"></div>
    <div class="field"><label>WhatsApp</label><input value="${formatPhone(p.phone)}" disabled><p class="field-hint">A alteração de número exigirá confirmação do novo WhatsApp quando a validação estiver conectada.</p></div>
    <div class="modal-actions"><button class="secondary-button" data-modal-close type="button">Cancelar</button><button class="gold-button" type="submit">Salvar</button></div>
  </form>`);
  $('#profileEditForm').addEventListener('submit',e=>{e.preventDefault();const fd=new FormData(e.currentTarget);p.name=String(fd.get('name')).trim();p.birthday=String(fd.get('birthday')||'');saveProfile(p);closeModal();toast('Dados atualizados.');renderProfile();renderHome()});
}

function modal(html){
  $('#modalBox').innerHTML=html; $('#modalBackdrop').classList.add('open'); $('#modalBackdrop').setAttribute('aria-hidden','false');
  $$('[data-modal-close]',$('#modalBox')).forEach(b=>b.addEventListener('click',closeModal));
}
function closeModal(){ $('#modalBackdrop').classList.remove('open'); $('#modalBackdrop').setAttribute('aria-hidden','true'); }

$$('[data-nav]').forEach(b=>b.addEventListener('click',()=>navigate(b.dataset.nav)));
$$('[data-action="start-booking"]').forEach(b=>b.addEventListener('click',()=>startBooking()));
$('#bookingBack').addEventListener('click',stepBack);
$$('.tab').forEach(t=>t.addEventListener('click',()=>{state.appointmentsTab=t.dataset.tab;renderAppointments()}));
$('#modalBackdrop').addEventListener('click',e=>{if(e.target===e.currentTarget)closeModal()});
document.addEventListener('keydown',e=>{if(e.key==='Escape')closeModal()});

renderHome();
renderAppointments();
renderProfile();

if('serviceWorker' in navigator){
  window.addEventListener('load',()=>navigator.serviceWorker.register('./sw.js').catch(()=>{}));
}
