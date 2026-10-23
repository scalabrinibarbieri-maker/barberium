// Barberium · Desempenho (etapa 7f, 23/10/2026).
//
// Antes eram dois remendos sobre a tela que o team.js desenhava:
//   v12.10 (barberium-v12.10.js): esperava o team.js desenhar o Desempenho, buscava o mesmo
//          resumo de novo e redesenhava tudo para incluir os produtos (6 cartões, serviços +
//          produtos), com observer e timers;
//   v12.33 (staff-tools-v12.33.js): acrescentava o cartão "Sua comissão" para o barbeiro, por
//          observer. Como a v12.10 redesenhava os cartões, o da comissão era tirado e posto de
//          novo, buscando a comissão mais de uma vez.
// Agora o team.js busca o resumo uma vez e desenha com este módulo. Mesmas funções do banco,
// mesmos textos.

const esc = (v = '') => String(v).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#039;' }[c]));
const dinheiro = (n) => new Intl.NumberFormat('pt-BR', { style: 'currency', currency: 'BRL' }).format((Number(n) || 0) / 100);

export function cartoesHtml(d) {
  const s = d?.summary || {};
  const vendas = Number(s.product_sales) || 0;
  const unidades = Number(s.product_units) || 0;
  return `
    <article class="performance-card gold">
      <small>Faturamento realizado</small>
      <strong>${dinheiro(s.realized_revenue_cents)}</strong>
      <em>Serviços + produtos</em>
    </article>
    <article class="performance-card">
      <small>Ainda agendado</small>
      <strong>${dinheiro(s.scheduled_revenue_cents)}</strong>
      <em>Horários confirmados</em>
    </article>
    <article class="performance-card">
      <small>Atendimentos</small>
      <strong>${Number(s.completed) || 0}</strong>
      <em>Concluídos</em>
    </article>
    <article class="performance-card">
      <small>Produtos vendidos</small>
      <strong>${unidades}</strong>
      <em>${vendas} venda${vendas === 1 ? '' : 's'} concluída${vendas === 1 ? '' : 's'}</em>
    </article>
    <article class="performance-card">
      <small>Ticket médio serviços</small>
      <strong>${dinheiro(s.average_ticket_cents)}</strong>
      <em>Sobre atendimentos concluídos</em>
    </article>
    <article class="performance-card">
      <small>Faturamento produtos</small>
      <strong>${dinheiro(s.product_revenue_cents)}</strong>
      <em>Vendas concluídas</em>
    </article>
  `;
}

export function listaHtml(d) {
  const servicos = (d?.services || []).map((x) => `
    <article class="service-stat">
      <div>
        <h3>${esc(x.service)}</h3>
        <p>${Number(x.appointments) || 0} horários • ${Number(x.completed) || 0} concluídos</p>
      </div>
      <strong>${dinheiro((Number(x.realized_revenue_cents) || 0) + (Number(x.scheduled_revenue_cents) || 0))}</strong>
    </article>
  `).join('');
  const produtos = (d?.products || []).map((x) => {
    const q = Number(x.quantity) || 0;
    return `
      <article class="service-stat">
        <div>
          <h3>${esc(x.product)}</h3>
          <p>Produto • ${q} unidade${q === 1 ? '' : 's'} vendida${q === 1 ? '' : 's'}</p>
        </div>
        <strong>${dinheiro(x.revenue_cents)}</strong>
      </article>
    `;
  }).join('');
  return servicos || produtos ? `${servicos}${produtos}` : '<div class="empty">Nenhum atendimento ou produto neste período.</div>';
}

// Cartão "Sua comissão" do barbeiro: aparece com "…" e é preenchido quando a comissão chega.
// aindaVale() diz se a tela ainda é a do mesmo período quando a resposta chegar.
export async function cartaoDeComissao(raiz, rpc, inicio, fim, aindaVale) {
  const cartao = document.createElement('article');
  cartao.id = 'v1233CommissionCard';
  cartao.className = 'performance-card';
  cartao.innerHTML = '<small>Sua comissão</small><strong>…</strong><em>Calculando período</em>';
  raiz.appendChild(cartao);
  try {
    const d = await rpc('barberium_staff_performance_v12_33', { p_start_date: inicio, p_end_date: fim });
    if (!aindaVale() || !cartao.isConnected) return;
    cartao.innerHTML = `
        <small>Sua comissão</small>
        <strong>${dinheiro(d?.summary?.commission_cents || 0)}</strong>
        <em>Gerada no período</em>`;
  } catch (err) {
    console.error('Comissão no desempenho:', err);
    if (!cartao.isConnected) return;
    cartao.innerHTML = `
          <small>Sua comissão</small>
          <strong>—</strong>
          <em>Não foi possível carregar</em>`;
  }
}
