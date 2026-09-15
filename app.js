const state = {
  view: 'home',
  selectedDate: null,
  selectedTime: null,
  bookings: JSON.parse(localStorage.getItem('barberium_bookings') || '[]')
};

const $ = (selector, scope = document) => scope.querySelector(selector);
const $$ = (selector, scope = document) => [...scope.querySelectorAll(selector)];

function navigate(view) {
  state.view = view;
  $$('.view').forEach(el => el.classList.toggle('active', el.dataset.view === view));
  $$('.nav-item').forEach(el => el.classList.toggle('active', el.dataset.go === view));
  if (view === 'appointments') renderAppointments();
  if (view === 'home') renderHomeBooking();
  window.scrollTo({ top: 0, behavior: 'smooth' });
}

function isoDate(date) {
  const y = date.getFullYear();
  const m = String(date.getMonth() + 1).padStart(2, '0');
  const d = String(date.getDate()).padStart(2, '0');
  return `${y}-${m}-${d}`;
}

function humanDate(value) {
  const date = new Date(`${value}T12:00:00`);
  return date.toLocaleDateString('pt-BR', { weekday: 'short', day: '2-digit', month: 'short' });
}

function renderDates() {
  const strip = $('#dateStrip');
  strip.innerHTML = '';
  const dayNames = ['dom', 'seg', 'ter', 'qua', 'qui', 'sex', 'sáb'];
  const today = new Date();

  let added = 0;
  let offset = 0;
  while (added < 5) {
    const date = new Date(today);
    date.setDate(today.getDate() + offset++);
    if (date.getDay() === 0) continue;

    const value = isoDate(date);
    if (!state.selectedDate) state.selectedDate = value;

    const btn = document.createElement('button');
    btn.type = 'button';
    btn.className = `date-option ${state.selectedDate === value ? 'active' : ''}`;
    btn.dataset.date = value;
    btn.innerHTML = `<small>${dayNames[date.getDay()]}</small><strong>${String(date.getDate()).padStart(2, '0')}</strong>`;
    btn.addEventListener('click', () => {
      state.selectedDate = value;
      state.selectedTime = null;
      renderDates();
      renderTimes();
    });
    strip.appendChild(btn);
    added++;
  }
}

function renderTimes() {
  const times = ['10:30','11:30','12:30','14:00','15:00','16:00','17:00','18:00','19:00','20:00'];
  const grid = $('#timeGrid');
  grid.innerHTML = '';

  times.forEach(time => {
    const btn = document.createElement('button');
    btn.type = 'button';
    btn.className = `time-option ${state.selectedTime === time ? 'active' : ''}`;
    btn.textContent = time;
    btn.addEventListener('click', () => {
      state.selectedTime = time;
      renderTimes();
    });
    grid.appendChild(btn);
  });
}

function showToast(message) {
  const toast = $('#toast');
  toast.textContent = message;
  toast.classList.add('show');
  clearTimeout(showToast.timer);
  showToast.timer = setTimeout(() => toast.classList.remove('show'), 2600);
}

function saveBookings() {
  localStorage.setItem('barberium_bookings', JSON.stringify(state.bookings));
}

function renderHomeBooking() {
  const card = $('#homeBookingCard');
  const next = [...state.bookings]
    .sort((a, b) => `${a.date} ${a.time}`.localeCompare(`${b.date} ${b.time}`))[0];

  if (!next) {
    card.className = 'next-booking empty-state';
    card.innerHTML = `<span class="eyebrow">PRÓXIMO HORÁRIO</span><h3>Nada marcado ainda</h3><p>Quando você agendar, seu próximo horário aparece aqui.</p>`;
    return;
  }

  card.className = 'next-booking has-booking';
  card.innerHTML = `
    <span class="eyebrow">PRÓXIMO HORÁRIO</span>
    <h3>${next.service}</h3>
    <p>${humanDate(next.date)} às ${next.time}</p>
    <div class="booking-meta">
      <span>${next.professional}</span>
      <span>Scalabrini Barbieri</span>
    </div>`;
}

function renderAppointments() {
  const list = $('#appointmentsList');
  if (!state.bookings.length) {
    list.innerHTML = `<div class="empty-appointments">Você ainda não tem horários agendados.</div>`;
    return;
  }

  list.innerHTML = '';
  [...state.bookings]
    .sort((a, b) => `${a.date} ${a.time}`.localeCompare(`${b.date} ${b.time}`))
    .forEach(booking => {
      const card = document.createElement('article');
      card.className = 'appointment-card';
      card.innerHTML = `
        <div class="appointment-top">
          <div>
            <h3>${booking.service}</h3>
            <p>${humanDate(booking.date)} • ${booking.time} • ${booking.professional}</p>
          </div>
          <span class="status">CONFIRMADO</span>
        </div>
        <div class="appointment-actions">
          <button type="button" data-reschedule="${booking.id}">Reagendar</button>
          <button type="button" class="danger" data-cancel="${booking.id}">Cancelar</button>
        </div>`;
      list.appendChild(card);
    });

  $$('[data-cancel]', list).forEach(btn => btn.addEventListener('click', () => {
    state.bookings = state.bookings.filter(b => b.id !== btn.dataset.cancel);
    saveBookings();
    renderAppointments();
    renderHomeBooking();
    showToast('Agendamento cancelado.');
  }));

  $$('[data-reschedule]', list).forEach(btn => btn.addEventListener('click', () => {
    const booking = state.bookings.find(b => b.id === btn.dataset.reschedule);
    if (booking) {
      const radio = $(`input[name="service"][value="${CSS.escape(booking.service)}"]`);
      if (radio) radio.checked = true;
      state.selectedDate = booking.date;
      state.selectedTime = booking.time;
      renderDates();
      renderTimes();
      navigate('booking');
      showToast('Escolha um novo dia ou horário.');
    }
  }));
}

function bindEvents() {
  $$('[data-go]').forEach(btn => btn.addEventListener('click', () => navigate(btn.dataset.go)));

  $$('.service-card').forEach(btn => btn.addEventListener('click', () => {
    const radio = $(`input[name="service"][value="${CSS.escape(btn.dataset.service)}"]`);
    if (radio) radio.checked = true;
    navigate('booking');
  }));

  $('#bookingForm').addEventListener('submit', event => {
    event.preventDefault();
    if (!state.selectedDate || !state.selectedTime) {
      showToast('Escolha o dia e o horário.');
      return;
    }

    const data = new FormData(event.currentTarget);
    const serviceInput = $('input[name="service"]:checked');
    const booking = {
      id: crypto.randomUUID ? crypto.randomUUID() : String(Date.now()),
      service: data.get('service'),
      professional: data.get('professional'),
      date: state.selectedDate,
      time: state.selectedTime,
      price: Number(serviceInput?.dataset.price || 0),
      createdAt: new Date().toISOString()
    };

    state.bookings.push(booking);
    saveBookings();
    renderHomeBooking();
    renderAppointments();
    navigate('appointments');
    showToast('Horário confirmado!');
  });
}

renderDates();
renderTimes();
renderHomeBooking();
renderAppointments();
bindEvents();

if ('serviceWorker' in navigator) {
  navigator.serviceWorker.register('./sw.js').catch(() => {});
}
