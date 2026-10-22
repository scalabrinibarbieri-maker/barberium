// Barberium · cancelar atendimentos (etapa 7d, parte 1, 22/10/2026).
//
// Antes eram três remendos, cada um com um caminho de cancelar, que roubavam o clique uns dos
// outros:
//   v12.8  (agenda-cancelados-v12.8.js): ADM cancela horário confirmado escolhendo o tipo
//          (normal ou engano) → barberium_staff_cancel_appointment_v2;
//   v12.45 (cancel-permission-v12.45.js): trocava o botão do barbeiro, com timers, para fugir
//          da v12.8 → barberium_staff_set_appointment_status (confirmando a permissão na hora);
//   v12.23 (em barberium-v12.17.js): cancelar atendimento concluído, separando anulação de
//          reembolso real → barberium_staff_cancel_completed_appointment_v12_23.
// Agora o team.js desenha os botões e chama estes fluxos direto. Mesmas funções do banco,
// mesmos textos e mensagens. As regras de quem pode o quê ficam para a parte 2 (banco).

const esc = (v = '') => String(v ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#039;' }[c]));
const dinheiro = (n) => new Intl.NumberFormat('pt-BR', { style: 'currency', currency: 'BRL' }).format((Number(n) || 0) / 100);
const $ = (s, r = document) => r.querySelector(s);
// Quanto tempo cada aviso fica na tela, como nos remendos antigos.
const AVISO = 2800;
const AVISO_CONCLUIDO = 3000;

// Aviso no detalhe de um cancelamento classificado como engano (antes: v12.8, buscando o
// detalhe de novo 350 ms depois).
export function notaDeEngano(d) {
  if (d?.status !== 'cancelled') return '';
  const engano = (d.events || []).some((e) => e?.details?.cancellation_kind === 'booking_error');
  return engano
    ? '<div class="v128-booking-error-note"><strong>Engano / erro de agendamento</strong><p>Este cancelamento foi classificado como correção operacional.</p></div>'
    : '';
}

// O barbeiro só vê "Cancelado" com a permissão de agora (o ADM pode ter mudado depois do login).
async function permissaoAgora(rpc) {
  const [me, catalogo] = await Promise.all([rpc('barberium_staff_me'), rpc('barberium_staff_catalog')]);
  const gestor = ['owner', 'admin'].includes(me?.role);
  return { gestor, pode: gestor || catalogo?.permissions?.cancel_appointment === true };
}
export async function podeCancelarAgora(rpc) {
  return (await permissaoAgora(rpc)).pode;
}

// ADM: cancelar horário confirmado, com o tipo (normal ou engano).
export function abrirCancelamento(id, ctx) {
  ctx.openModal('CANCELAR ATENDIMENTO', 'Classificar cancelamento', `
    <form id="v128CancelForm" class="form-grid">
      <div class="field">
        <label>Tipo do cancelamento</label>
        <select id="v128CancelKind">
          <option value="regular" selected>Cancelamento normal</option>
          <option value="booking_error">Engano / erro de agendamento</option>
        </select>
      </div>
      <p class="v128-cancel-help">
        Use “Engano / erro de agendamento” quando a comanda foi criada por engano, no barbeiro errado,
        horário errado ou em outra situação operacional semelhante.
      </p>
      <div class="field">
        <label>Observação (opcional)</label>
        <textarea id="v128CancelReason" placeholder="Ex.: marcado para o barbeiro errado"></textarea>
      </div>
      <button class="danger-btn finance-wide" type="submit">Confirmar cancelamento</button>
    </form>`);
  const form = $('#v128CancelForm');
  form.onsubmit = async (e) => {
    e.preventDefault();
    const botao = form.querySelector('[type=submit]');
    if (botao.disabled) return;
    const tipo = $('#v128CancelKind').value;
    const digitado = $('#v128CancelReason').value.trim();
    botao.disabled = true;
    botao.textContent = 'Cancelando…';
    try {
      await ctx.rpc('barberium_staff_cancel_appointment_v2', {
        p_appointment_id: id, p_cancellation_kind: tipo,
        p_reason: digitado || (tipo === 'booking_error' ? 'Engano / erro de agendamento' : 'Cancelamento normal'),
      });
      ctx.toast(tipo === 'booking_error' ? 'Cancelado como engano/erro de agendamento.' : 'Atendimento cancelado.', AVISO);
      ctx.closeModal();
      ctx.loadAgenda();
    } catch (err) {
      ctx.toast(err?.message || 'Não foi possível cancelar.', AVISO);
      botao.disabled = false;
      botao.textContent = 'Confirmar cancelamento';
    }
  };
}

// Barbeiro com a permissão: cancela direto, depois de confirmar.
export async function cancelarComoBarbeiro(id, botao, ctx) {
  if (!id || botao?.disabled) return;
  try {
    const agora = await permissaoAgora(ctx.rpc);
    // Virou ADM depois do login: o cancelamento é o administrativo (com o tipo), como antes.
    if (agora.gestor) { ctx.toast('Use o cancelamento administrativo deste atendimento.', AVISO); return; }
    if (!agora.pode) {
      botao?.remove();
      ctx.toast('Você não tem permissão para cancelar agendamentos.', AVISO);
      return;
    }
    if (!confirm('Cancelar este agendamento?')) return;
    botao.disabled = true;
    botao.textContent = 'Cancelando…';
    await ctx.rpc('barberium_staff_set_appointment_status', { p_appointment_id: id, p_status: 'cancelled' });
    ctx.toast('Agendamento cancelado.', AVISO);
    ctx.closeModal();
    ctx.loadAgenda();
  } catch (err) {
    ctx.toast(err?.message || 'Não foi possível cancelar o agendamento.', AVISO);
    if (botao) { botao.disabled = false; botao.textContent = 'Cancelado'; }
  }
}

// ADM: cancelar atendimento concluído. (Nos parágrafos .detail-note o espaço em branco aparece na
// tela, white-space: pre-wrap: o recuo das linhas é o mesmo de antes.) "ISTO FOI REEMBOLSO" separa o dinheiro devolvido de
// verdade (fica no histórico como reembolso) do lançamento por engano (é anulado).
export async function abrirCancelamentoConcluido(id, ctx) {
  ctx.openModal('CANCELAR ATENDIMENTO CONCLUÍDO', 'Conferir cancelamento', '<div class="loading">Conferindo pagamentos e produtos…</div>');
  try {
    const [d, f, p] = await Promise.all([
      ctx.rpc('barberium_staff_appointment_detail', { p_appointment_id: id }),
      ctx.rpc('barberium_staff_appointment_finance', { p_appointment_id: id }),
      ctx.rpc('barberium_staff_appointment_products', { p_appointment_id: id }),
    ]);
    const servico = Math.max(0, Number(f.paid_cents || 0) - Number(f.refunds_cents || 0));
    const produtos = p.status === 'completed' ? Number(p.paid_cents || 0) : 0;
    const pendente = Number(f.receivable?.remaining_cents || 0) + (p.status === 'completed' ? Number(p.pending_cents || 0) : 0);
    const plano = (f.uses || []).some((u) => u.status === 'consumed');

    ctx.openModal('CANCELAR ATENDIMENTO CONCLUÍDO', d.customer?.name || 'Atendimento', `
      <form id="v1223CancelCompletedForm" class="form-grid">
        <div class="detail-grid">
          <div class="detail-box"><small>Valor registrado no serviço</small><strong>${dinheiro(servico)}</strong></div>
          <div class="detail-box"><small>Valor registrado em produtos</small><strong>${dinheiro(produtos)}</strong></div>
          <div class="detail-box wide"><small>Total registrado na comanda</small><strong>${dinheiro(servico + produtos)}</strong></div>
        </div>
        <div class="field">
          <label>Tipo do cancelamento</label>
          <select id="v1223CancellationKind">
            <option value="booking_error">Engano / erro operacional</option>
            <option value="regular">Cancelamento normal</option>
          </select>
        </div>
        <label class="check-row">
          <input id="v1223IsRefund" type="checkbox">
          <span>ISTO FOI REEMBOLSO</span>
        </label>
        <p class="v128-cancel-help">
          Marque somente se o dinheiro realmente entrou e depois foi devolvido ao cliente.
          Se foi erro de lançamento/agendamento e o dinheiro nunca entrou, deixe desmarcado.
        </p>
        <div id="v1223NoRefundNote" class="detail-note">
          <p><strong>Sem reembolso:</strong> o Barberium vai anular os recebimentos registrados por engano.
            Eles não aparecerão como faturamento nem como reembolso.</p>
        </div>
        <div id="v1223RefundNote" class="detail-note hidden">
          <p><strong>Com reembolso:</strong> o recebimento permanece no histórico e a devolução entra
            no Financeiro como reembolso real.</p>
        </div>
        <div id="v1223RefundMethodWrap" class="field hidden">
          <label>Forma da devolução</label>
          <select id="v1223RefundMethod">
            <option value="">Selecione</option>
            <option value="pix">Pix</option>
            <option value="cash">Dinheiro</option>
            <option value="debit">Débito</option>
            <option value="credit">Crédito</option>
            <option value="transfer">Transferência</option>
            <option value="other">Outro</option>
          </select>
        </div>
        <div class="detail-note">
          <p>O cancelamento reverte as comissões e devolve produtos ao estoque.
            ${pendente > 0 ? ` O saldo pendente de ${dinheiro(pendente)} será cancelado.` : ''}
            ${plano ? ' A ficha do plano/pacote será devolvida.' : ''}</p>
        </div>
        <div class="field">
          <label>Motivo do cancelamento</label>
          <textarea id="v1223Reason" minlength="3" required placeholder="Ex.: atendimento lançado por engano"></textarea>
        </div>
        <button id="v1223ConfirmCancel" class="danger-btn finance-wide" type="submit">Cancelar sem registrar reembolso</button>
      </form>`);

    const form = $('#v1223CancelCompletedForm');
    const reembolso = $('#v1223IsRefund');
    const forma = $('#v1223RefundMethod');
    const botao = $('#v1223ConfirmCancel');
    const sincronizar = () => {
      const sim = reembolso.checked;
      $('#v1223RefundMethodWrap').classList.toggle('hidden', !sim);
      $('#v1223NoRefundNote').classList.toggle('hidden', sim);
      $('#v1223RefundNote').classList.toggle('hidden', !sim);
      forma.required = sim;
      botao.textContent = sim ? 'Cancelar e registrar reembolso' : 'Cancelar sem registrar reembolso';
    };
    reembolso.addEventListener('change', sincronizar);
    sincronizar();

    form.onsubmit = async (e) => {
      e.preventDefault();
      if (botao.disabled) return;
      const comReembolso = reembolso.checked;
      const metodo = comReembolso ? forma.value : null;
      if (comReembolso && !metodo) { ctx.toast('Selecione a forma da devolução.', AVISO_CONCLUIDO); return; }
      botao.disabled = true;
      const texto = botao.textContent;
      botao.textContent = 'Cancelando…';
      try {
        await ctx.rpc('barberium_staff_cancel_completed_appointment_v12_23', {
          p_appointment_id: id, p_reason: $('#v1223Reason').value.trim(),
          p_cancellation_kind: $('#v1223CancellationKind').value, p_is_refund: comReembolso, p_refund_method: metodo,
        });
        ctx.toast(comReembolso ? 'Atendimento cancelado e reembolso registrado.' : 'Atendimento cancelado sem reembolso. Lançamentos incorretos foram anulados.', AVISO_CONCLUIDO);
        ctx.closeModal();
        ctx.loadAgenda();
      } catch (err) {
        ctx.toast(err?.message || 'Não foi possível cancelar.', AVISO_CONCLUIDO);
        botao.disabled = false;
        botao.textContent = texto;
      }
    };
  } catch (err) {
    const corpo = $('#modalBody');
    if (corpo) corpo.innerHTML = `<div class="empty">${esc(err?.message || 'Não foi possível conferir o atendimento.')}</div>`;
  }
}
