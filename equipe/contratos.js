// Barberium · Contratos ativos (etapa 7e, 23/10/2026).
//
// Antes eram dois remendos:
//   v12.9  (barberium-v12.9.js): mudava a aba Planos de lugar para criar as abas "Planos" e
//          "Contratos ativos", desenhava os contratos (pagamento integral, ajuste de créditos,
//          cancelar pacote) e roubava o clique de "Ajustar créditos" da ficha do cliente;
//   v12.17 (barberium-v12.17.js): observava classes da tela e o foco do aparelho para buscar
//          o saldo de novo, apertando sozinho o botão "Contratos ativos".
// Agora as abas vêm escritas no index.html e o team.js chama este módulo. Mesmas funções do
// banco, mesmos textos e mensagens.

const esc = (v = '') => String(v).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#039;' }[c]));
const $ = (s, r = document) => r.querySelector(s);
const $$ = (s, r = document) => [...r.querySelectorAll(s)];
const AVISO = 2800; // quanto tempo cada mensagem fica na tela, como na v12.9
const dinheiro = (cents) => new Intl.NumberFormat('pt-BR', { style: 'currency', currency: 'BRL' }).format((Number(cents) || 0) / 100);
function data(value) {
  if (!value) return '—';
  const s = String(value).slice(0, 10);
  const [y, m, d] = s.split('-');
  return y && m && d ? `${d}/${m}/${y}` : s;
}
const situacao = (v) => ({ active: 'Ativa', pending: 'Pendente', paused: 'Pausada', overdue: 'Atrasada', cancelled: 'Cancelada', expired: 'Vencida' })[v] || v || '—';
function centavos(v) {
  let s = String(v ?? '').trim().replace(/[^\d,.-]/g, '');
  if (s.includes(',')) s = s.replace(/\./g, '').replace(',', '.');
  const n = Number(s);
  return Number.isFinite(n) ? Math.round(n * 100) : 0;
}

let ctx = null; // { rpc, openModal, closeModal, toast, painelVisivel }
let contratos = [];
let modo = 'catalog';
let espera = null;
let ultimaBusca = 0;
const aviso = (msg) => ctx.toast(msg, AVISO);

export function ligarContratos(c) {
  ctx = c;
  $$('[data-v129-plan-mode]').forEach((btn) => { btn.onclick = () => mudarModo(btn.dataset.v129PlanMode); });
  $('#v129ContractSearch').oninput = desenhar;
  // Voltando para o app com "Contratos ativos" aberto, o saldo é buscado de novo (antes v12.17).
  document.addEventListener('visibilitychange', () => { if (!document.hidden) atualizarSeVisivel(); });
  window.addEventListener('focus', atualizarSeVisivel);
}

// Chamado pelo team.js ao abrir a aba Planos do Financeiro: mantém a aba interna escolhida.
export function mostrarPlanos() {
  mudarModo(modo);
}

function contratosVisiveis() {
  return ctx?.painelVisivel() && !$('#financePlansTab')?.classList.contains('hidden') && !$('#v129ContractsTab')?.classList.contains('hidden');
}
function atualizarSeVisivel() {
  clearTimeout(espera);
  espera = setTimeout(() => {
    if (!contratosVisiveis()) return;
    const agora = Date.now();
    if (agora - ultimaBusca < 350) return;
    carregar();
  }, 120);
}

function mudarModo(m) {
  modo = m === 'contracts' ? 'contracts' : 'catalog';
  $$('[data-v129-plan-mode]').forEach((b) => b.classList.toggle('active', b.dataset.v129PlanMode === modo));
  $('#v129PlanCatalogTab')?.classList.toggle('hidden', modo !== 'catalog');
  $('#v129ContractsTab')?.classList.toggle('hidden', modo !== 'contracts');
  if (modo === 'contracts') carregar();
}

async function carregar() {
  const root = $('#v129ContractsList');
  if (!root) return;
  ultimaBusca = Date.now();
  root.innerHTML = '<div class="loading">Carregando contratos…</div>';
  try {
    contratos = await ctx.rpc('barberium_staff_membership_contracts');
    desenhar();
  } catch (err) {
    root.innerHTML = `<div class="empty">${esc(err?.message || 'Não foi possível carregar os contratos.')}</div>`;
  }
}

function resumoDeCreditos(m) {
  return (m.credits || []).map((c) => {
    if (c.unlimited) return `<span>${esc(c.service)}: <b>Ilimitado</b></span>`;
    const rotulo = m.plan_type === 'subscription' ? 'uso(s)' : 'crédito(s)';
    return `<span>${esc(c.service)}: <b>${Number(c.available) || 0} ${rotulo}</b></span>`;
  }).join('');
}

function desenhar() {
  const root = $('#v129ContractsList');
  if (!root) return;
  const q = ($('#v129ContractSearch')?.value || '').trim().toLocaleLowerCase('pt-BR');
  const linhas = contratos.filter((m) => !q || `${m.customer || ''} ${m.name || ''} ${m.phone || ''}`.toLocaleLowerCase('pt-BR').includes(q));
  if (!linhas.length) {
    root.innerHTML = `<div class="empty">${q ? 'Nenhum contrato encontrado.' : 'Nenhum contrato ativo no momento.'}</div>`;
    return;
  }
  root.innerHTML = linhas.map((m) => `
    <article class="plan-card">
      <div class="plan-head">
        <div>
          <span class="plan-tag">${m.plan_type === 'subscription' ? 'ASSINATURA' : 'PACOTE'} • ${esc(situacao(m.status))}</span>
          <h3>${esc(m.customer)}</h3>
          <p>${esc(m.name)} • ${dinheiro(m.price_cents)}${m.phone ? ` • ${esc(m.phone)}` : ''}</p>
        </div>
        <button class="soft-btn" data-v129-contract="${m.id}" type="button">Configurar</button>
      </div>
      <div class="credit-mini">${resumoDeCreditos(m)}</div>
    </article>
  `).join('');
  $$('[data-v129-contract]').forEach((btn) => {
    btn.onclick = () => {
      const m = contratos.find((x) => x.id === btn.dataset.v129Contract);
      if (m) abrirContrato(m);
    };
  });
}

function abrirContrato(m) {
  const pagamentoPendente = m.plan_type === 'package'
    ? m.status === 'pending'
    : (m.cycles || []).some((c) => ['pending', 'overdue'].includes(c.status));
  const estado = m.plan_type === 'subscription'
    ? `${m.paused_until ? `<div class="notice-box">Pausada até ${data(m.paused_until)}.</div>` : ''}${m.renewal_blocked ? `<div class="notice-box">Cancelamento programado${m.cancel_effective_on ? ` para ${data(m.cancel_effective_on)}` : ''}.</div>` : ''}`
    : '';
  ctx.openModal('CONTRATO', m.customer, `
    <div class="v129-contract-summary">
      <div class="detail-grid">
        <div class="detail-box"><small>Plano</small><strong>${esc(m.name)}</strong></div>
        <div class="detail-box"><small>Status</small><strong>${esc(situacao(m.status))}</strong></div>
        <div class="detail-box"><small>Tipo</small><strong>${m.plan_type === 'subscription' ? 'Assinatura' : 'Pacote'}</strong></div>
        <div class="detail-box"><small>Valor</small><strong>${dinheiro(m.price_cents)}</strong></div>
        <div class="detail-box wide"><small>Cliente</small><strong>${esc(m.customer)}${m.phone ? ` • ${esc(m.phone)}` : ''}</strong></div>
      </div>
      ${estado}
      <h3 class="section-mini-title">${m.plan_type === 'subscription' ? 'Benefícios' : 'Créditos'}</h3>
      <div class="credit-grid">
        ${(m.credits || []).map((c) => `
          <div>
            <small>${esc(c.service)}</small>
            <strong>${c.unlimited ? 'Ilimitado' : `${Number(c.available) || 0} disponível(is)`}</strong>
            <span>${Number(c.used) || 0} usado(s) • ${Number(c.reserved) || 0} reservado(s)${c.expires_on ? ` • vence ${data(c.expires_on)}` : ''}</span>
          </div>
        `).join('') || '<div><small>Benefícios</small><strong>Aguardando pagamento integral</strong></div>'}
      </div>
      <div class="v129-contract-actions">
        ${pagamentoPendente ? `<button class="gold-btn" data-v129-pay="${m.id}" type="button">Confirmar pagamento integral</button>` : ''}
        ${m.plan_type === 'package' && m.status === 'active' ? `
          <button class="soft-btn" data-v129-adjust="${m.id}" type="button">Ajustar créditos</button>
          <button class="danger-btn" data-v129-cancel="${m.id}" type="button">Cancelar pacote</button>
        ` : ''}
      </div>
    </div>
  `);
  $('[data-v129-pay]')?.addEventListener('click', () => abrirPagamento(m));
  $('[data-v129-adjust]')?.addEventListener('click', () => abrirAjusteDeCreditos(m));
  $('[data-v129-cancel]')?.addEventListener('click', () => abrirCancelamento(m));
}

// Também usado pelo "Ajustar créditos" da ficha do cliente (antes a v12.9 roubava esse clique).
export function abrirAjusteDeCreditos(m) {
  const finitos = (m.credits || []).filter((c) => !c.unlimited);
  if (!finitos.length) { aviso('Este pacote não possui créditos finitos para ajustar.'); return; }
  ctx.openModal('PACOTE', `Ajustar créditos • ${m.name}`, `
    <form id="v129CreditForm" class="form-grid">
      <div class="field"><label>Benefício</label><select id="v129CreditBucket">${finitos.map((c) => `<option value="${c.bucket_id}">${esc(c.service)} • ${Number(c.available) || 0} disponíveis</option>`).join('')}</select></div>
      <div class="field"><label>Operação</label><select id="v129CreditOperation"><option value="add">Somar créditos</option><option value="subtract">Subtrair créditos</option></select></div>
      <div class="field"><label>Quantidade</label><input id="v129CreditQuantity" type="number" inputmode="numeric" min="1" step="1" placeholder="Ex.: 1" required></div>
      <div class="field"><label>Motivo obrigatório</label><textarea id="v129CreditReason" required></textarea></div>
      <button class="gold-btn" type="submit">Registrar ajuste</button>
    </form>
  `);
  $('#v129CreditForm').onsubmit = async (e) => {
    e.preventDefault();
    const qtd = Number($('#v129CreditQuantity').value);
    if (!Number.isInteger(qtd) || qtd <= 0) { aviso('Informe uma quantidade inteira maior que zero.'); return; }
    const delta = $('#v129CreditOperation').value === 'subtract' ? -qtd : qtd;
    const motivo = $('#v129CreditReason').value.trim();
    if (!motivo) { aviso('Informe o motivo do ajuste.'); return; }
    const btn = e.target.querySelector('[type=submit]');
    btn.disabled = true;
    try {
      await ctx.rpc('barberium_staff_adjust_package_credit', { p_membership_id: m.id, p_bucket_id: $('#v129CreditBucket').value, p_delta: delta, p_reason: motivo });
      aviso('Créditos ajustados e registrados no histórico.');
      ctx.closeModal();
      await carregar();
    } catch (err) {
      aviso(err?.message || 'Não foi possível ajustar os créditos.');
      btn.disabled = false;
    }
  };
}

// "Ajustar créditos" da ficha do cliente: a ficha tem o contrato com outro formato; busca o da
// lista de contratos, como a v12.9 fazia.
export async function abrirAjusteDoCliente(id) {
  try {
    if (!contratos.length) contratos = await ctx.rpc('barberium_staff_membership_contracts');
    const m = contratos.find((x) => x.id === id);
    if (!m) throw new Error('Contrato não encontrado.');
    abrirAjusteDeCreditos(m);
  } catch (err) {
    aviso(err?.message || 'Não foi possível abrir o ajuste de créditos.');
  }
}

function abrirPagamento(m) {
  const ciclo = (m.cycles || []).find((c) => ['pending', 'overdue'].includes(c.status));
  ctx.openModal('PAGAMENTO INTEGRAL', m.name, `
    <div class="detail-grid">
      <div class="detail-box wide"><small>Valor integral</small><strong>${dinheiro(ciclo?.amount_cents || m.price_cents)}</strong></div>
      ${ciclo ? `<div class="detail-box"><small>Vencimento</small><strong>${data(ciclo.due_date)}</strong></div><div class="detail-box"><small>Status</small><strong>${esc(situacao(ciclo.status))}</strong></div>` : ''}
    </div>
    <div class="notice-box">O plano só será ativado após a confirmação deste pagamento integral.</div>
    <form id="v129PaymentForm" class="form-grid">
      <div class="field"><label>Forma de pagamento</label><select id="v129PaymentMethod"><option value="pix">Pix</option><option value="cash">Dinheiro</option><option value="debit">Débito</option><option value="credit">Crédito</option></select></div>
      <button class="gold-btn" type="submit">Confirmar pagamento integral</button>
    </form>
  `);
  $('#v129PaymentForm').onsubmit = async (e) => {
    e.preventDefault();
    const btn = e.target.querySelector('[type=submit]');
    btn.disabled = true;
    try {
      await ctx.rpc('barberium_staff_record_membership_payment', { p_membership_id: m.id, p_cycle_id: ciclo?.id || null, p_method: $('#v129PaymentMethod').value });
      aviso(m.plan_type === 'subscription' ? 'Pagamento confirmado. Benefícios liberados.' : 'Pagamento confirmado. Créditos liberados.');
      ctx.closeModal();
      await carregar();
    } catch (err) {
      aviso(err?.message || 'Não foi possível confirmar o pagamento.');
      btn.disabled = false;
    }
  };
}

function abrirCancelamento(m) {
  const politica = m.rules?.refund_mode || 'nonrefundable';
  const rotulos = {
    nonrefundable: 'Sem reembolso',
    proportional: 'Reembolso proporcional ao saldo não usado',
    manual: 'Reembolso definido pelo ADM',
    no_after_use: 'Cancelamento somente antes do primeiro uso',
  };
  ctx.openModal('CANCELAR PACOTE', m.name, `
    <div class="notice-box">Política deste pacote: <strong>${esc(rotulos[politica] || politica)}</strong>.</div>
    <form id="v129CancelForm" class="form-grid">
      <div class="field"><label>Motivo obrigatório</label><textarea id="v129CancelReason" required></textarea></div>
      ${politica === 'manual' ? '<div class="field"><label>Valor do reembolso</label><input id="v129ManualRefund" inputmode="decimal" value="0,00"></div>' : ''}
      <button class="danger-btn" type="submit">Confirmar cancelamento</button>
    </form>
  `);
  $('#v129CancelForm').onsubmit = async (e) => {
    e.preventDefault();
    if (!confirm('Confirmar o cancelamento deste pacote?')) return;
    const motivo = $('#v129CancelReason').value.trim();
    if (!motivo) { aviso('Informe o motivo do cancelamento.'); return; }
    const btn = e.target.querySelector('[type=submit]');
    btn.disabled = true;
    try {
      const r = await ctx.rpc('barberium_staff_cancel_package', {
        p_membership_id: m.id,
        p_reason: motivo,
        p_manual_refund_cents: politica === 'manual' ? centavos($('#v129ManualRefund').value) : null,
      });
      aviso(r?.refund_cents > 0 ? `Pacote cancelado. Reembolso: ${dinheiro(r.refund_cents)}` : 'Pacote cancelado.');
      ctx.closeModal();
      await carregar();
    } catch (err) {
      aviso(err?.message || 'Não foi possível cancelar o pacote.');
      btn.disabled = false;
    }
  };
}
