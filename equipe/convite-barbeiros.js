// Barberium · ADM convida os barbeiros da barbearia (22/10/2026).
//
// Na tela Equipe, cada profissional sem login tem o botão "Convidar"; quem já tem login de
// barbeiro tem "Senha nova" (para quando esquece a senha). O ADM informa o e-mail (que será o
// login) e o WhatsApp do barbeiro; o banco cria o convite e a função de convite do Supabase
// devolve o link, que vai pelo WhatsApp. O barbeiro abre, cria a senha e entra com o papel de
// barbeiro, ligado àquele profissional.
//
// O cadastro do profissional na agenda é o que gera o alerta de cobrança no painel do dono do
// Barberium (no banco), não este convite.

const esc = (v) => String(v ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#039;' }[c]));

function linkDoConvite(codigo, tipo) {
  const url = new URL('equipe/', location.origin + '/');
  const t = window.BARBERIUM_TENANT;
  if (t?.enderecoDeTeste) url.searchParams.set('barbearia', t.barbershopSlug);
  url.searchParams.set('convite', codigo);
  url.searchParams.set('tipo', tipo);
  return url.toString();
}

function enderecoDaEquipe() {
  const url = new URL('equipe/', location.origin + '/');
  const t = window.BARBERIUM_TENANT;
  if (t?.enderecoDeTeste) url.searchParams.set('barbearia', t.barbershopSlug);
  return url.toString();
}

// p: profissional da lista da Equipe ({professional_id, name, login_active, login_email}).
// ctx: funções do team.js ({openModal, closeModal, toast, api}).
export function abrirConviteDoBarbeiro(p, { openModal, toast, api }) {
  const senhaNova = !!p.login_active;
  openModal(senhaNova ? 'SENHA NOVA' : 'CONVITE', p.name, `
    <p class="campaign-help">${senhaNova
      ? 'Gere um link para o barbeiro escolher uma senha nova. Ele vale uma vez só.'
      : 'O barbeiro recebe um link pelo WhatsApp, cria a senha e entra na Área da Equipe vendo só o que você liberou em Permissões.'}</p>
    <form id="conviteBarbeiroForm" style="display:grid;gap:12px">
      <div class="field"><label>E-mail do barbeiro (será o login)</label>
        <input id="conviteBarbeiroEmail" type="email" required maxlength="120" autocapitalize="none" placeholder="barbeiro@email.com" value="${esc(p.login_email || '')}" ${senhaNova ? 'readonly' : ''}></div>
      <div class="field"><label>WhatsApp do barbeiro</label>
        <input id="conviteBarbeiroWhats" inputmode="tel" maxlength="20" placeholder="(11) 90000-0000"></div>
      <button id="conviteBarbeiroGerar" class="gold-btn" type="submit">${senhaNova ? 'Gerar link de senha nova' : 'Gerar convite'}</button>
      <p class="form-error" id="conviteBarbeiroErro"></p>
    </form>
    <div id="conviteBarbeiroResultado"></div>`);
  const $ = (id) => document.getElementById(id);
  $('conviteBarbeiroForm').addEventListener('submit', async (e) => {
    e.preventDefault();
    const botao = $('conviteBarbeiroGerar');
    botao.disabled = true;
    botao.textContent = 'Gerando…';
    $('conviteBarbeiroErro').textContent = '';
    try {
      const convite = await api.rpc('barberium_staff_invite_barber', {
        p_professional_id: p.professional_id, p_email: $('conviteBarbeiroEmail').value, p_whatsapp: $('conviteBarbeiroWhats').value,
      });
      const c = await api.requisicao('/functions/v1/barberium-convite', { method: 'POST', body: JSON.stringify({ convite: convite.invite_id }) });
      const link = linkDoConvite(c.codigo, c.tipo);
      const primeiro = String(p.name || '').split(/\s+/)[0];
      const texto = c.tipo === 'invite'
        ? `Olá, ${primeiro}! Você foi convidado para a Área da Equipe da ${c.barbearia} no Barberium.\n\nPara criar sua senha, abra este link (ele vale uma vez só):\n${link}\n\nDepois, é só entrar em ${enderecoDaEquipe()} com o seu e-mail e essa senha.`
        : `Olá, ${primeiro}! Para escolher uma senha nova na Área da Equipe da ${c.barbearia}, abra este link (ele vale uma vez só):\n${link}`;
      const whats = c.whatsapp ? `https://wa.me/${c.whatsapp}?text=${encodeURIComponent(texto)}` : `https://wa.me/?text=${encodeURIComponent(texto)}`;
      $('conviteBarbeiroForm').style.display = 'none';
      $('conviteBarbeiroResultado').innerHTML = `
        <p class="campaign-help">Link pronto para ${esc(primeiro)}. Ele vale uma vez só e vence em pouco tempo; se vencer, gere outro aqui.</p>
        <textarea id="conviteBarbeiroTexto" readonly rows="7" style="width:100%;border:1px solid rgba(255,255,255,.09);background:#07160f;color:var(--text);border-radius:12px;padding:11px;font-size:12px">${esc(texto)}</textarea>
        <a class="gold-btn" style="display:block;text-align:center;text-decoration:none;margin-top:10px" href="${esc(whats)}" target="_blank" rel="noopener">Enviar pelo WhatsApp</a>
        <button id="conviteBarbeiroCopiar" class="soft-btn" type="button" style="width:100%;margin-top:8px">Copiar mensagem</button>`;
      $('conviteBarbeiroCopiar').onclick = async () => {
        try { await navigator.clipboard.writeText(texto); toast('Mensagem copiada.'); } catch { $('conviteBarbeiroTexto').select(); toast('Selecione e copie a mensagem.'); }
      };
    } catch (err) {
      $('conviteBarbeiroErro').textContent = err.message || 'Não foi possível gerar o convite.';
      botao.disabled = false;
      botao.textContent = senhaNova ? 'Gerar link de senha nova' : 'Gerar convite';
    }
  });
}
