// Barberium · Ajustes → Barbearia → cartão "Área do cliente" (etapa 7a, 22/10/2026).
//
// Junta num lugar só o que antes eram três remendos que se corrigiam uns aos outros:
//   v12.24 (cartão de aparência, injetado por observer e protegendo o salvar da unidade
//   dentro do fetch), v12.28/v12.47 (apresentação e manutenção, injetadas no mesmo cartão)
//   e v12.42 (salvava por XHR para fugir da proteção da v12.24).
// Agora o banco grava só as chaves que recebe (migration 20261022200000), então este
// cartão manda só as dele, e o formulário da unidade manda só as regras da agenda.
// Mesmos campos, textos, ids e mensagens de antes.

const esc = (v = '') => String(v ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#039;' }[c]));

const PADRAO = {
  titulo: 'Agende seu horário.',
  chamada: 'Experiências',
  tituloServicos: 'Nossos serviços',
  apresentacao: 'Trabalhamos com uma seleção premium de atendimentos para manter sua experiência mais prática e elegante. Ao tocar em Agendar agora, você verá todos os serviços disponíveis com seus respectivos valores e duração.',
  destaques: 'Cortes, barba tradicional e barba express\nCombos completos com barba, sobrancelha e barboterapia\nBarboterapia, sobrancelha, pezinho detalhes e cabeça raspada',
  botao: 'Ver serviços e agendar →',
  mensagemManutencao: 'Estamos realizando uma atualização. Os agendamentos online voltarão em breve.',
};

function aviso(msg) {
  const t = document.querySelector('#toast');
  if (!t) return;
  t.textContent = msg;
  t.classList.add('show');
  clearTimeout(aviso.relogio);
  aviso.relogio = setTimeout(() => t.classList.remove('show'), 3000);
}

// O cartão, logo abaixo de "Barbearia", para a unidade escolhida no topo de Ajustes.
export function cartaoAreaDoCliente(u) {
  if (!u?.id) return '';
  const st = u.settings || {};
  const topo = String(u.name || '').replace(/\s+[—–-]\s+/, ' • ') || u.name || '';
  const destaques = Array.isArray(st.client_services_bullets) ? st.client_services_bullets.join('\n') : (st.client_services_bullets || PADRAO.destaques);
  const manutencao = st.client_maintenance_mode == null ? true : st.client_maintenance_mode === true;
  return `<form id="v1224ClientAppearance" class="settings-card">
    <div class="settings-card-head">
      <div>
        <h2>Área do cliente</h2>
        <p>Personalize a identidade pública desta unidade.</p>
      </div>
      <span class="tag">SITE</span>
    </div>
    <p class="v1224-client-note">
      Unidade selecionada: <strong>${esc(u.name)}</strong>.
      O nome principal da barbearia vem do campo “Nome da barbearia” logo acima.
    </p>
    <div class="settings-two">
      <div class="field">
        <label>Texto no topo</label>
        <input id="v1224HeaderSubtitle" value="${esc(st.client_header_subtitle || topo)}" placeholder="Ex.: II Unidade • Bragança Paulista">
      </div>
      <div class="field">
        <label>Texto sobre a capa</label>
        <input id="v1224HeroLabel" value="${esc(st.client_hero_label || u.name || '')}" placeholder="Ex.: II Unidade — Bragança Paulista">
      </div>
    </div>
    <div class="field">
      <label>Título principal</label>
      <input id="v1224HeroTitle" value="${esc(st.client_hero_title || PADRAO.titulo)}" placeholder="Ex.: Agende seu horário.">
    </div>
    <div id="v1228PresentationFields">
      <h3 class="settings-section-title">Disponibilidade da Área do Cliente</h3>
      <p class="settings-hint">Use esta opção para interromper temporariamente o acesso dos clientes sem afetar a Área da Equipe.</p>
      <label class="permission-item">
        <span><strong>Modo manutenção da Área do Cliente</strong><small>Quando ligado, clientes não conseguem acessar o agendamento, perfil ou horários.</small></span>
        <input id="v1247MaintenanceMode" type="checkbox" ${manutencao ? 'checked' : ''}>
      </label>
      <div class="field">
        <label>Mensagem durante a manutenção</label>
        <textarea id="v1247MaintenanceMessage" rows="3" placeholder="Ex.: Voltaremos em breve.">${esc(st.client_maintenance_message || PADRAO.mensagemManutencao)}</textarea>
        <small class="v1224-helper">Se houver WhatsApp cadastrado na unidade, o cliente verá um botão para falar com a barbearia.</small>
      </div>
      <h3 class="settings-section-title">Apresentação da página inicial</h3>
      <p class="settings-hint">Personalize o bloco que apresenta os serviços ao cliente. Em “Destaques”, use uma linha para cada item.</p>
      <div class="settings-two">
        <div class="field"><label>Chamada da seção</label><input id="v1228ServicesKicker" value="${esc(st.client_services_kicker || PADRAO.chamada)}" placeholder="Ex.: Experiências"></div>
        <div class="field"><label>Título da seção</label><input id="v1228ServicesTitle" value="${esc(st.client_services_title || PADRAO.tituloServicos)}" placeholder="Ex.: Nossos serviços"></div>
      </div>
      <div class="field"><label>Texto de apresentação</label><textarea id="v1228ServicesIntro" rows="5" placeholder="Conte ao cliente como é a experiência da barbearia.">${esc(st.client_services_intro || PADRAO.apresentacao)}</textarea></div>
      <div class="field"><label>Destaques</label><textarea id="v1228ServicesBullets" rows="5" placeholder="Uma linha por destaque">${esc(destaques)}</textarea><small class="v1224-helper">Deixe vazio se não quiser mostrar a lista.</small></div>
      <div class="field"><label>Texto do botão</label><input id="v1228ServicesCta" value="${esc(st.client_services_cta || PADRAO.botao)}" placeholder="Ex.: Ver serviços e agendar →"></div>
    </div>
    <div class="v1224-media-grid">
      <div class="v1224-media-card">
        <label>Logo exibida ao cliente</label>
        <img id="v1224LogoPreview" class="v1224-media-preview v1224-logo-preview" src="${esc(st.client_logo_url || '../assets/logo-sb.webp')}" alt="">
        <input id="v1224LogoFile" type="file" accept="image/jpeg,image/png,image/webp">
        <input id="v1224LogoUrl" type="hidden" value="${esc(st.client_logo_url || '')}">
        <small class="v1224-helper">JPG, PNG ou WebP · máximo 5 MB.</small>
      </div>
      <div class="v1224-media-card">
        <label>Foto grande de capa</label>
        <img id="v1224HeroPreview" class="v1224-media-preview" src="${esc(st.client_hero_image_url || '../assets/barbearia.webp')}" alt="">
        <input id="v1224HeroFile" type="file" accept="image/jpeg,image/png,image/webp">
        <input id="v1224HeroUrl" type="hidden" value="${esc(st.client_hero_image_url || '')}">
        <small class="v1224-helper">Esta é a foto que ocupa o fundo da tela inicial.</small>
      </div>
    </div>
    <button class="gold-btn" type="submit">Salvar personalização</button>
  </form>`;
}

// Liga os envios de imagem e o salvar.
//   ctx.rpc(nome, args), ctx.enviarImagem(arquivo, pasta) → URL pública,
//   ctx.unidadeAtual() → a unidade mais recente (depois de recarregar), ctx.recarregar().
export function ligarAreaDoCliente(ctx) {
  const form = document.querySelector('#v1224ClientAppearance');
  if (!form) return;
  const $ = (s) => form.querySelector(s);

  const ligarImagem = (arquivo, campo, previa, pasta) => {
    const input = $(arquivo);
    input.addEventListener('change', async () => {
      const file = input.files?.[0];
      if (!file || form.dataset.uploading === '1') return;
      form.dataset.uploading = '1';
      input.disabled = true;
      const salvar = $('[type=submit]');
      salvar.disabled = true;
      aviso('Enviando imagem…');
      try {
        const url = await ctx.enviarImagem(file, pasta);
        $(campo).value = url;
        $(previa).src = url;
        aviso('Imagem enviada. Toque em Salvar personalização.');
      } catch (err) {
        aviso(err?.message || 'Não foi possível enviar a imagem.');
      } finally {
        delete form.dataset.uploading;
        input.disabled = false;
        salvar.disabled = false;
      }
    });
  };
  ligarImagem('#v1224LogoFile', '#v1224LogoUrl', '#v1224LogoPreview', 'client/logo');
  ligarImagem('#v1224HeroFile', '#v1224HeroUrl', '#v1224HeroPreview', 'client/hero');

  form.onsubmit = async (event) => {
    event.preventDefault();
    if (form.dataset.uploading === '1') { aviso('Aguarde o envio da imagem terminar.'); return; }
    const botao = $('[type=submit]');
    botao.disabled = true;
    botao.textContent = 'Salvando…';
    try {
      // Os dados da unidade (nome, cidade…) vêm frescos do banco, como antes.
      await ctx.recarregar();
      const u = ctx.unidadeAtual();
      if (!u) throw new Error('Unidade não encontrada.');
      const destaques = $('#v1228ServicesBullets').value.split(/\r?\n/).map((x) => x.trim()).filter(Boolean);
      await ctx.rpc('barberium_staff_save_unit', {
        p_unit_id: u.id, p_name: u.name, p_city: u.city || null, p_state: u.state || null,
        p_whatsapp: u.whatsapp || null, p_maps_url: u.maps_url || null, p_is_active: u.is_active !== false,
        // Só as chaves deste cartão: o banco mantém as outras.
        p_settings: {
          client_header_subtitle: $('#v1224HeaderSubtitle').value.trim(),
          client_hero_label: $('#v1224HeroLabel').value.trim(),
          client_hero_title: $('#v1224HeroTitle').value.trim() || PADRAO.titulo,
          client_logo_url: $('#v1224LogoUrl').value.trim(),
          client_hero_image_url: $('#v1224HeroUrl').value.trim(),
          client_services_kicker: $('#v1228ServicesKicker').value.trim() || PADRAO.chamada,
          client_services_title: $('#v1228ServicesTitle').value.trim() || PADRAO.tituloServicos,
          client_services_intro: $('#v1228ServicesIntro').value.trim(),
          client_services_bullets: destaques,
          client_services_cta: $('#v1228ServicesCta').value.trim() || PADRAO.botao,
          client_maintenance_mode: $('#v1247MaintenanceMode').checked,
          client_maintenance_message: $('#v1247MaintenanceMessage').value.trim() || PADRAO.mensagemManutencao,
        },
      });
      await ctx.recarregar();
      aviso('Personalização salva.');
      botao.textContent = 'Salvo ✓';
      setTimeout(() => { if (form.isConnected) { botao.disabled = false; botao.textContent = 'Salvar personalização'; } }, 1400);
    } catch (err) {
      aviso(err?.message || 'Não foi possível salvar.');
      botao.disabled = false;
      botao.textContent = 'Salvar personalização';
    }
  };
}
