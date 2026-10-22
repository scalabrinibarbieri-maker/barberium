// Barberium · "Novo horário", "Novo encaixe" e "Editar atendimento" (etapa 7c, 22/10/2026):
// vários serviços na mesma comanda e cliente passageiro.
//
// Antes eram dois remendos que reescreviam o pedido ao banco dentro do fetch:
//   v12.13 (barberium-v12.13.js): trocava 5 chamadas pelas versões _v12_12 e lia do DOM os
//   serviços extras; v12.21 (em barberium-v12.17.js): trocava a criação pela versão _v12_21
//   e acionava o botão "+ Novo cliente" do team.js para o passageiro.
// Agora o team.js chama direto as funções do banco que já eram usadas (criar: _v12_21, que
// também cria o cliente passageiro; editar e horários livres: _v12_12), e este módulo cuida
// da caixa "Serviços da comanda" e do botão "Cliente passageiro", com os mesmos ids e textos.

const esc = (v = '') => String(v ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#039;' }[c]));
const dinheiro = (n) => new Intl.NumberFormat('pt-BR', { style: 'currency', currency: 'BRL' }).format((Number(n) || 0) / 100);
const $ = (s, r = document) => r.querySelector(s);
const $$ = (s, r = document) => [...r.querySelectorAll(s)];

const servico = (catalogo, id) => (catalogo?.services || []).find((s) => s.id === id);
const permitido = (s, profissional) => !profissional || !Array.isArray(s?.professional_ids) || s.professional_ids.includes(profissional);

// Estado inicial: na edição, os serviços extras que o atendimento já tem.
export function estadoDaComanda(detalhe) {
  const lista = detalhe?.extra_services || [];
  return {
    extraIds: lista.map((x) => x.service_id),
    extraFotos: new Map(lista.map((x) => [x.service_id, {
      id: x.service_id, name: x.name, price_cents: Number(x.price_cents) || 0, duration_min: Number(x.duration_min) || 0,
    }])),
    passenger: false,
  };
}

function infoExtra(st, catalogo, id) {
  const s = servico(catalogo, id);
  if (s) return { id, name: s.name, price_cents: Number(s.price_cents) || 0, duration_min: Number(s.duration_min) || 0 };
  return st.extraFotos.get(id) || { id, name: 'Serviço', price_cents: 0, duration_min: 0 };
}

// Os extras que valem: nem o serviço principal, nem um adicional marcado, e só os que o
// profissional faz.
export function extrasValidos(st, catalogo) {
  const adicionais = new Set(st.addonIds || []);
  return st.extraIds.filter((id) => id !== st.serviceId && !adicionais.has(id))
    .filter((id) => { const s = servico(catalogo, id); return !s || permitido(s, st.professionalId); });
}

export function precoDosExtras(st, catalogo) {
  return extrasValidos(st, catalogo).reduce((total, id) => total + (Number(infoExtra(st, catalogo, id).price_cents) || 0), 0);
}

// Tira os extras que deixaram de valer (mudou o serviço, o profissional ou os adicionais).
// Devolve true se tirou algum.
export function sanearExtras(st, catalogo) {
  const antes = st.extraIds.length;
  st.extraIds = extrasValidos(st, catalogo);
  return st.extraIds.length !== antes;
}

export function caixaServicosHtml(bloqueado) {
  return `<div id="v1212ExtraServiceBox" class="field">
    <label>Serviços da comanda</label>
    <div id="v1212SelectedServices" class="unit-breakdown"></div>
    <button id="v1212AddService" class="soft-btn" type="button" ${bloqueado ? 'disabled' : ''}>+ Adicionar serviço</button>
    <div id="v1212ServicePicker" class="form-grid hidden">
      <div class="field">
        <label>Outro serviço</label>
        <select id="v1212ServiceSelect"></select>
      </div>
      <button id="v1212ConfirmService" class="soft-btn" type="button">Adicionar à comanda</button>
    </div>
  </div>`;
}

export function passageiroHtml() {
  return `<div id="v1221PassengerWrap" class="action-row">
    <button id="v1221PassengerButton" class="soft-btn" type="button">Cliente passageiro</button>
    <small style="align-self:center;opacity:.72">Use quando não houver nome ou WhatsApp do cliente.</small>
  </div>`;
}

// Desenha a lista de extras e as opções do seletor.
export function desenharExtras(st, catalogo, aoMudar) {
  const lista = $('#v1212SelectedServices');
  if (!lista) return;
  const podeMudar = !$('#bookingService')?.disabled;
  lista.innerHTML = st.extraIds.length
    ? st.extraIds.map((id) => {
      const s = infoExtra(st, catalogo, id);
      return `<div class="unit-breakdown-row">
        <span><strong>${esc(s.name)}</strong><small>${dinheiro(s.price_cents)} • ${s.duration_min} min</small></span>
        <button class="soft-btn small" data-v1212-remove-service="${id}" type="button" ${podeMudar ? '' : 'disabled'}>Remover</button>
      </div>`;
    }).join('')
    : '<div class="empty">Nenhum outro serviço adicionado.</div>';
  $$('[data-v1212-remove-service]', lista).forEach((b) => {
    b.onclick = () => {
      st.extraIds = st.extraIds.filter((id) => id !== b.dataset.v1212RemoveService);
      desenharExtras(st, catalogo, aoMudar);
      aoMudar();
    };
  });

  const select = $('#v1212ServiceSelect');
  if (!select) return;
  const adicionais = new Set(st.addonIds || []);
  const opcoes = (catalogo?.services || []).filter((s) => s.id !== st.serviceId && !st.extraIds.includes(s.id) && !adicionais.has(s.id) && permitido(s, st.professionalId));
  select.innerHTML = opcoes.length
    ? `<option value="">Selecione outro serviço</option>${opcoes.map((s) => `<option value="${s.id}">${esc(s.name)} • ${dinheiro(s.price_cents)}</option>`).join('')}`
    : '<option value="">Nenhum outro serviço disponível</option>';
  $('#v1212ConfirmService').disabled = !opcoes.length;
}

// Liga "+ Adicionar serviço" e "Adicionar à comanda". aoMudar: preço e horários livres.
export function ligarExtras(st, catalogo, aoMudar) {
  if (!$('#v1212ExtraServiceBox')) return;
  desenharExtras(st, catalogo, aoMudar);
  $('#v1212AddService').onclick = () => {
    const seletor = $('#v1212ServicePicker');
    seletor.classList.toggle('hidden');
    if (!seletor.classList.contains('hidden')) desenharExtras(st, catalogo, aoMudar);
  };
  $('#v1212ConfirmService').onclick = () => {
    const id = $('#v1212ServiceSelect').value;
    if (!id) return;
    st.extraIds = [...st.extraIds, id];
    $('#v1212ServicePicker').classList.add('hidden');
    desenharExtras(st, catalogo, aoMudar);
    aoMudar();
  };
}

// Liga o botão "Cliente passageiro" (só em horário/encaixe novo).
export function ligarPassageiro(st) {
  const form = $('#bookingForm');
  const botao = $('#v1221PassengerButton', form);
  if (!botao) return;
  botao.onclick = () => {
    st.passenger = !st.passenger;
    const busca = $('#customerSearch', form);
    const acoes = $('#searchCustomerButton', form)?.closest('.action-row');
    const novos = $('#newCustomerFields', form);
    const escolhido = $('#selectedCustomerWrap', form);
    const resultados = $('#customerResults', form);
    const nome = $('#newCustomerName', form);
    const fone = $('#newCustomerPhone', form);
    st.customer = { id: null, name: '', phone: '' };
    if (resultados) resultados.innerHTML = '';
    novos?.classList.add('hidden');
    if (st.passenger) {
      st.newCustomer = true;
      if (nome) nome.value = 'Cliente passageiro';
      if (fone) fone.value = '';
      if (busca) busca.value = '';
      busca?.closest('.field')?.classList.add('hidden');
      acoes?.classList.add('hidden');
      if (escolhido) escolhido.innerHTML = '<div class="selected-customer"><strong>Cliente passageiro</strong><small>Sem nome, WhatsApp ou cadastro na base de clientes</small></div>';
      botao.textContent = 'Usar cliente identificado';
    } else {
      st.newCustomer = false;
      if (nome) nome.value = '';
      if (fone) fone.value = '';
      busca?.closest('.field')?.classList.remove('hidden');
      acoes?.classList.remove('hidden');
      if (escolhido) escolhido.innerHTML = '';
      botao.textContent = 'Cliente passageiro';
    }
  };
}
