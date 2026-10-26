// Barberium · Saldos do Financeiro (etapa 7g, parte 2, 26/10/2026).
//
// Antes (v12.39, em balances-v12.39.js): a aba "Saldos" era posta no Financeiro por timers, com
// estilos injetados, e escutava cliques e as classes da tela para saber quando fechar. Agora a
// aba e o painel vêm escritos no index.html, os estilos estão no team.css, e o team.js abre e
// fecha a aba por este módulo. Mesma função do banco (barberium_staff_balance_quick), mesmos
// textos e números.

const $ = (s, r = document) => r.querySelector(s);
const $$ = (s, r = document) => [...r.querySelectorAll(s)];
const pad = (n) => String(n).padStart(2, '0');
const dataIso = (d) => `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
const esc = (v = '') => String(v ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#039;' }[c]));
const dinheiro = (n) => new Intl.NumberFormat('pt-BR', { style: 'currency', currency: 'BRL' }).format((Number(n) || 0) / 100);

let ctx = null; // { rpc, openModal, isManager }
let ativo = false;
let gestor = false;
let pedido = 0;

function hoje() {
  const d = new Date();
  d.setHours(12, 0, 0, 0);
  return d;
}

function periodoPronto(tipo) {
  const fim = hoje();
  const inicio = new Date(fim);
  if (tipo === 'yesterday') {
    inicio.setDate(inicio.getDate() - 1);
    return [dataIso(inicio), dataIso(inicio)];
  }
  if (tipo === '7days') {
    inicio.setDate(inicio.getDate() - 6);
    return [dataIso(inicio), dataIso(fim)];
  }
  if (tipo === 'month') {
    inicio.setDate(1);
    return [dataIso(inicio), dataIso(fim)];
  }
  return [dataIso(fim), dataIso(fim)];
}

function rotuloDoPeriodo(inicio, fim) {
  const fmt = new Intl.DateTimeFormat('pt-BR', { day: '2-digit', month: 'short', year: 'numeric' });
  const a = fmt.format(new Date(`${inicio}T12:00:00`));
  const b = fmt.format(new Date(`${fim}T12:00:00`));
  return inicio === fim ? a : `${a} — ${b}`;
}

function enderecoDaImagem(v) {
  const s = String(v || '').trim();
  if (!s) return '../barberium.svg';
  if (/^https?:\/\//i.test(s)) return s;
  if (s.startsWith('../')) return s;
  return `../${s.replace(/^\.?\//, '')}`;
}

const rotuloDaCategoria = (v) => ({ services: 'Serviços', products: 'Produtos', memberships: 'Assinaturas' })[v] || 'Comissão';
const rotuloDaSituacao = (v) => ({ open: 'Em aberto', settled: 'Paga', paid: 'Paga' })[v] || v || '';

function dataHora(v, fuso) {
  try {
    return new Intl.DateTimeFormat('pt-BR', {
      timeZone: fuso || 'America/Sao_Paulo',
      day: '2-digit', month: '2-digit', year: '2-digit',
      hour: '2-digit', minute: '2-digit',
    }).format(new Date(v));
  } catch {
    return String(v || '');
  }
}

export function ligarSaldos(c) {
  ctx = c;
  const [a, b] = periodoPronto('today');
  $('#v1239Start').value = a;
  $('#v1239End').value = b;
  $('#v1239Start').addEventListener('change', () => {
    if ($('#v1239Start').value > $('#v1239End').value) $('#v1239End').value = $('#v1239Start').value;
    limparPeriodoPronto();
    carregar();
  });
  $('#v1239End').addEventListener('change', () => {
    if ($('#v1239End').value < $('#v1239Start').value) $('#v1239Start').value = $('#v1239End').value;
    limparPeriodoPronto();
    carregar();
  });
  $('#v1239Unit').addEventListener('change', () => {
    const geral = $('#financeUnit');
    if (geral) geral.value = $('#v1239Unit').value;
    carregar();
  });
  $$('[data-v1239-preset]').forEach((btn) => {
    btn.addEventListener('click', () => {
      const [inicio, fim] = periodoPronto(btn.dataset.v1239Preset);
      $('#v1239Start').value = inicio;
      $('#v1239End').value = fim;
      $$('[data-v1239-preset]').forEach((x) => x.classList.toggle('active', x === btn));
      carregar();
    });
  });
}

function limparPeriodoPronto() {
  $$('[data-v1239-preset]').forEach((x) => x.classList.remove('active'));
}

function unidades() {
  const caixa = $('#v1239UnitWrap');
  const propria = $('#v1239Unit');
  if (!gestor) {
    caixa.classList.add('hidden');
    propria.innerHTML = '';
    return;
  }
  const geral = $('#financeUnit');
  if (geral?.options?.length) {
    propria.innerHTML = geral.innerHTML;
    propria.value = geral.value || '';
  }
  caixa.classList.remove('hidden');
}

export function abrirSaldos() {
  ativo = true;
  gestor = ctx.isManager();
  $$('[data-finance-tab]').forEach((b) => b.classList.remove('active'));
  $('#v1239BalancesTab').classList.add('active');
  $$('.finance-tab-panel').forEach((p) => p.classList.add('hidden'));
  $('#financeBalancesTab').classList.remove('hidden');
  $('#financeAdminControls')?.classList.add('hidden');
  unidades();
  if (!$$('[data-v1239-preset].active').length) $('[data-v1239-preset="today"]')?.classList.add('active');
  carregar();
}

// O team.js pergunta antes de abrir a aba de sempre ao terminar de carregar o Financeiro: quem
// tocou em Saldos enquanto carregava continua em Saldos.
export function saldosAberto() {
  return ativo;
}

// Chamado pelo team.js ao trocar de aba do Financeiro ou de painel.
export function fecharSaldos() {
  if (!ativo) return;
  ativo = false;
  $('#v1239BalancesTab')?.classList.remove('active');
  $('#financeBalancesTab')?.classList.add('hidden');
  if (ctx.isManager()) $('#financeAdminControls')?.classList.remove('hidden');
}

async function carregar() {
  if (!ativo) return;
  const inicio = $('#v1239Start')?.value;
  const fim = $('#v1239End')?.value;
  if (!inicio || !fim) return;
  const atual = ++pedido;
  $('#v1239PeriodLabel').textContent = rotuloDoPeriodo(inicio, fim);
  $('#v1239Content').innerHTML = '<div class="loading">Carregando saldos…</div>';
  try {
    const d = await ctx.rpc('barberium_staff_balance_quick', { p_start: inicio, p_end: fim, p_unit_id: gestor ? ($('#v1239Unit')?.value || null) : null });
    if (atual !== pedido || !ativo) return;
    desenhar(d);
  } catch (err) {
    console.error('Saldos rápidos:', err);
    if (atual !== pedido) return;
    $('#v1239Content').innerHTML = `<div class="empty">${esc(err?.message || 'Não foi possível carregar os saldos.')}</div>`;
  }
}

function desenhar(data) {
  const root = $('#v1239Content');
  if (!root) return;
  const pros = data?.professionals || [];
  const daCasa = (data?.role || 'manager') === 'manager';
  $('#v1239ScopeLabel').textContent = daCasa ? 'Casa + comissões da equipe' : 'Sua comissão no período';
  const c = data?.categories || {};
  const marca = $('.brand-line img')?.getAttribute('src') || '../assets/logo-sb.webp';

  const categoriasDaCasa = daCasa ? `
      <div class="v1239-categories">
        <article class="v1239-category">
          <small>Serviços</small>
          <strong>${dinheiro(c.services?.net_cents || 0)}</strong>
          <em>líquido</em>
        </article>
        <article class="v1239-category">
          <small>Produtos</small>
          <strong>${dinheiro(c.products?.net_cents || 0)}</strong>
          <em>líquido</em>
        </article>
        <article class="v1239-category">
          <small>Assinaturas</small>
          <strong>${dinheiro(c.memberships?.net_cents || 0)}</strong>
          <em>líquido</em>
        </article>
      </div>` : '';

  const doBarbeiro = !daCasa && pros[0] ? `
      <div class="v1239-categories">
        <article class="v1239-category">
          <small>Serviços</small>
          <strong>${dinheiro(pros[0].service_commission_cents || 0)}</strong>
          <em>comissão</em>
        </article>
        <article class="v1239-category">
          <small>Produtos</small>
          <strong>${dinheiro(pros[0].product_commission_cents || 0)}</strong>
          <em>comissão</em>
        </article>
        <article class="v1239-category">
          <small>Assinaturas</small>
          <strong>${dinheiro(pros[0].membership_commission_cents || 0)}</strong>
          <em>comissão</em>
        </article>
      </div>` : '';

  const casa = daCasa ? `
      <button class="v1239-person house" data-v1239-house type="button">
        <span class="v1239-avatar"><img src="${esc(marca)}" alt=""></span>
        <strong>Casa</strong>
        <b>${dinheiro(data.house_cents || 0)}</b>
        <small>Líquido − comissões</small>
      </button>` : '';

  const cartoes = pros.map((p) => `
      <button class="v1239-person" data-v1239-pro="${esc(p.professional_id)}" type="button">
        <span class="v1239-avatar"><img src="${esc(enderecoDaImagem(p.image_path))}" alt=""></span>
        <strong>${esc(p.name)}</strong>
        <b>${dinheiro(p.commission_cents || 0)}</b>
        <small>Comissão no período</small>
      </button>`).join('');

  root.innerHTML = `
      ${categoriasDaCasa}
      ${doBarbeiro}
      <div class="v1239-section-head">
        <small>SALDOS</small>
        <h2>${daCasa ? 'Visão rápida' : 'Seu saldo'}</h2>
        <p>Toque em um card para ver de onde veio o valor.</p>
      </div>
      <div class="v1239-balances">${casa}${cartoes}</div>
      ${!pros.length ? '<div class="empty">Nenhum profissional encontrado neste período.</div>' : ''}
    `;
  $('[data-v1239-house]', root)?.addEventListener('click', () => mostrarCasa(data));
  $$('[data-v1239-pro]', root).forEach((btn) => btn.addEventListener('click', () => mostrarProfissional(data, btn.dataset.v1239Pro)));
}

function mostrarCasa(data) {
  const c = data?.categories || {};
  ctx.openModal('SALDOS', 'Casa', `
      <div class="v1239-house-lines">
        <div class="v1239-house-line"><span>Serviços líquidos</span><strong>${dinheiro(c.services?.net_cents || 0)}</strong></div>
        <div class="v1239-house-line"><span>Produtos líquidos</span><strong>${dinheiro(c.products?.net_cents || 0)}</strong></div>
        <div class="v1239-house-line"><span>Assinaturas / planos líquidos</span><strong>${dinheiro(c.memberships?.net_cents || 0)}</strong></div>
        <div class="v1239-house-line"><span>Total recebido líquido</span><strong>${dinheiro(data.net_received_cents || 0)}</strong></div>
        <div class="v1239-house-line"><span>− Comissões geradas</span><strong>${dinheiro(data.commissions_cents || 0)}</strong></div>
        <div class="v1239-house-line total"><span>Casa</span><strong>${dinheiro(data.house_cents || 0)}</strong></div>
      </div>
      <p class="v1239-note">Visão rápida antes das demais despesas operacionais e do custo dos produtos. Para DRE completo, use a aba Visão/Relatórios.</p>
    `);
}

function mostrarProfissional(data, id) {
  const p = (data?.professionals || []).find((x) => x.professional_id === id);
  if (!p) return;
  const lancamentos = (data?.entries || []).filter((x) => x.professional_id === id);
  ctx.openModal('COMISSÕES', p.name, `
      <div class="v1239-breakdown">
        <article><small>Serviços</small><strong>${dinheiro(p.service_commission_cents || 0)}</strong></article>
        <article><small>Produtos</small><strong>${dinheiro(p.product_commission_cents || 0)}</strong></article>
        <article><small>Assinaturas</small><strong>${dinheiro(p.membership_commission_cents || 0)}</strong></article>
      </div>
      <div class="v1239-house-line total" style="padding-top:0;margin-bottom:13px">
        <span>Total do período</span><strong>${dinheiro(p.commission_cents || 0)}</strong>
      </div>
      <div class="v1239-detail-list">
        ${lancamentos.length ? lancamentos.map((x) => `
          <article class="v1239-entry">
            <div>
              <h4>${esc(x.description || rotuloDaCategoria(x.category))}</h4>
              <p>${esc(rotuloDaCategoria(x.category))} • ${esc(dataHora(x.created_at, data.timezone))} • ${esc(rotuloDaSituacao(x.status))}</p>
            </div>
            <strong>${dinheiro(x.amount_cents || 0)}</strong>
          </article>
        `).join('') : '<div class="empty">Nenhuma comissão gerada neste período.</div>'}
      </div>
    `);
}
