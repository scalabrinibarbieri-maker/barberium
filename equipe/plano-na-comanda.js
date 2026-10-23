// Barberium · Ficha de plano no "Concluído" (etapa 7e, 23/10/2026).
//
// Antes (v12.20, em barberium-v12.17.js): um interceptador do fetch espiava qual atendimento
// estava aberto, e um observer injetava a caixa "Cliente de plano" quando via o botão
// "Concluir atendimento". Para mostrar o valor novo depois de usar ou tirar uma ficha, fechava a
// janela, tocava no cartão da agenda e no "Concluído" sozinho.
// Agora o team.js desenha a caixa junto com o pagamento e, depois de usar ou tirar a ficha,
// abre o pagamento de novo direto. Mesmas funções do banco, mesmos textos e mensagens.

const esc = (v = '') => String(v).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#039;' }[c]));
const dinheiro = (n) => new Intl.NumberFormat('pt-BR', { style: 'currency', currency: 'BRL' }).format((Number(n) || 0) / 100);
const $$ = (s, r = document) => [...r.querySelectorAll(s)];
const AVISO = 3000; // quanto tempo cada mensagem fica na tela, como na v12.20

const situacaoDaFicha = (s) => ({ reserved: 'Ficha selecionada', consumed: 'Ficha utilizada', forfeited: 'Ficha consumida', decision_required: 'Aguardando decisão' })[s] || s;
function disponivel(o) {
  if (o.unlimited) return 'Ilimitado';
  const n = Number(o.available) || 0;
  return `${n} ficha${n === 1 ? '' : 's'} disponível${n === 1 ? '' : 'is'}`;
}

function caixaHtml(contexto, financeiro) {
  const opcoes = contexto?.options || [];
  const usos = (financeiro?.uses || []).filter((u) => ['reserved', 'consumed', 'forfeited', 'decision_required'].includes(u.status));
  const planos = [...new Set((contexto?.plans || []).map((p) => p.plan).filter(Boolean))];
  const usosHtml = usos.map((u) => `<article class="service-stat v1220-use-card"><div><h3>${esc(u.plan)} • ${esc(u.service)}</h3><p>${esc(situacaoDaFicha(u.status))} • cobre ${dinheiro(u.coverage_cents)}</p></div>${u.status === 'reserved' ? `<button class="soft-btn small" data-v1220-release="${u.id}" type="button">Não usar esta ficha</button>` : ''}</article>`).join('');
  const opcoesHtml = opcoes.map((o, i) => `<article class="service-stat v1220-option-card"><div><h3>${esc(o.target_service)}</h3><p>${esc(o.plan)} • ${esc(o.covered_service)} • ${esc(disponivel(o))}</p><p>Abatimento nesta comanda: <strong>${dinheiro(o.coverage_cents)}</strong></p></div><button class="gold-btn small" data-v1220-option="${i}" type="button">Usar ficha</button></article>`).join('');
  const nenhuma = !usos.length && !opcoes.length ? '<div class="empty">Este cliente possui plano, mas não há ficha disponível ou aplicável aos serviços desta comanda.</div>' : '';
  return `<section id="v1220MembershipCheckout"><div class="detail-note"><small>CLIENTE DE PLANO</small><p>${planos.length ? esc(planos.join(' • ')) : 'Plano ativo'} — escolha abaixo se este atendimento será abatido por ficha.</p></div>${usosHtml}${opcoesHtml}${nenhuma}</section>`;
}

// Desenha a caixa no topo do pagamento quando o cliente tem plano. ctx = { rpc, toast, reabrir }.
export function desenharFichaDoPlano(raiz, id, contexto, financeiro, ctx) {
  if (!contexto?.has_plan || raiz.querySelector('#v1220MembershipCheckout')) return;
  const caixa = document.createElement('div');
  caixa.innerHTML = caixaHtml(contexto, financeiro);
  const secao = caixa.firstElementChild;
  const primeiro = raiz.querySelector('.detail-note,.detail-grid');
  if (primeiro) raiz.insertBefore(secao, primeiro); else raiz.prepend(secao);
  const aviso = (msg) => ctx.toast(msg, AVISO);
  $$('[data-v1220-option]', secao).forEach((btn) => {
    const o = (contexto.options || [])[Number(btn.dataset.v1220Option)];
    if (!o) return;
    btn.onclick = async () => {
      btn.disabled = true;
      btn.textContent = 'Aplicando ficha…';
      try {
        await ctx.rpc('barberium_staff_reserve_membership_use', { p_appointment_id: id, p_membership_id: o.membership_id, p_benefit_id: o.benefit_id, p_bucket_id: o.bucket_id || null, p_target_service_id: o.target_service_id });
        aviso('Ficha aplicada à comanda.');
        ctx.reabrir();
      } catch (e) {
        aviso(e?.message || 'Não foi possível aplicar a ficha.');
        btn.disabled = false;
        btn.textContent = 'Usar ficha';
      }
    };
  });
  $$('[data-v1220-release]', secao).forEach((btn) => {
    const uso = (financeiro.uses || []).find((u) => u.id === btn.dataset.v1220Release);
    if (!uso) return;
    btn.onclick = async () => {
      btn.disabled = true;
      btn.textContent = 'Removendo…';
      try {
        await ctx.rpc('barberium_staff_release_membership_use', { p_use_id: uso.id });
        aviso('Ficha removida desta comanda.');
        ctx.reabrir();
      } catch (e) {
        aviso(e?.message || 'Não foi possível remover a ficha.');
        btn.disabled = false;
        btn.textContent = 'Não usar esta ficha';
      }
    };
  });
}
