// Barberium · Horários livres da Agenda (etapa 7f, 23/10/2026).
//
// Antes (v12.33, em staff-tools-v12.33.js): o botão "Horários livres" era posto na Agenda por
// timers e abria esta janela. Agora o botão vem escrito no index.html e o team.js chama este
// módulo. Mesma função do banco, mesmos textos.

const $ = (s, r = document) => r.querySelector(s);
const pad = (n) => String(n).padStart(2, '0');
const dataIso = (d) => `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
const esc = (v = '') => String(v ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#039;' }[c]));

function duracao(min) {
  min = Number(min) || 0;
  if (min < 60) return `${min} min`;
  const h = Math.floor(min / 60);
  const m = min % 60;
  return m ? `${h}h ${m}min` : `${h}h`;
}

// ctx = { rpc, openModal }
export async function abrirHorariosLivres(ctx) {
  const data = $('#dateInput')?.value || dataIso(new Date());
  const profissional = $('[data-filter-prof].active')?.dataset?.filterProf || null;
  ctx.openModal('AGENDA', 'Horários livres', '<div class="loading">Buscando horários livres…</div>');
  try {
    const d = await ctx.rpc('barberium_staff_free_ranges', { p_date: data, p_professional_id: profissional });
    const pros = d?.professionals || [];
    if (!pros.length) {
      $('#modalBody').innerHTML = '<div class="empty">Nenhum profissional disponível para esta data.</div>';
      return;
    }
    const hoje = dataIso(new Date());
    $('#modalBody').innerHTML = `
        <div class="detail-note">
          <small>DATA</small>
          <p><strong>${esc($('#dateLabel')?.textContent || data)}</strong></p>
          <p>As faixas abaixo já descontam agendamentos que bloqueiam a agenda e bloqueios do profissional.</p>
        </div>
        <div class="v1233-free-list">
          ${pros.map((p) => {
            const faixas = p.ranges || [];
            const fechado = p.is_closed === true;
            const vazio = fechado ? 'Sem expediente nesta data.' : (data === hoje ? 'Nenhuma faixa livre restante hoje.' : 'Nenhuma faixa livre nesta data.');
            return `
              <section class="v1233-free-pro">
                <div class="v1233-free-head">
                  <div>
                    <h3>${esc(p.professional)}</h3>
                    <small>${fechado ? 'Sem expediente' : `Expediente ${esc(p.open_time)}–${esc(p.close_time)}`}</small>
                  </div>
                  ${!fechado ? `<span class="v1233-free-count">${faixas.length} faixa${faixas.length === 1 ? '' : 's'}</span>` : ''}
                </div>
                ${faixas.length ? `
                  <div class="v1233-free-ranges">
                    ${faixas.map((r) => `
                      <div class="v1233-free-range">
                        <strong>${esc(r.start)}–${esc(r.end)}</strong>
                        <span>${duracao(r.duration_min)} livres</span>
                      </div>
                    `).join('')}
                  </div>
                ` : `<div class="v1233-free-empty">${vazio}</div>`}
              </section>`;
          }).join('')}
        </div>`;
  } catch (err) {
    console.error('Horários livres:', err);
    $('#modalBody').innerHTML = `<div class="empty">${esc(err?.message || 'Não foi possível carregar os horários livres.')}</div>`;
  }
}
