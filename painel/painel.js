// Barberium · painel do dono do SaaS (21/10/2026).
// Só abre com um login que está em barberium.platform_admins (o banco confere em toda chamada).
// Lista as barbearias e cadastra uma nova: barbearia, primeira unidade, endereço
// <nome>.barberium.pages.dev e o convite do dono dela, que vira um link para mandar no WhatsApp.
import { criarCliente, lerSessao, salvarSessao, limparSessao } from '../shared/api.js?v=1';

const { requisicao, rpc } = criarCliente();
const ACOES_ENDERECOS = 'https://github.com/scalabrinibarbieri-maker/barberium/actions/workflows/enderecos.yml';

const $ = (s) => document.querySelector(s);
const esc = (v) => String(v ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#039;' }[c]));
const dataBR = (v) => (v ? new Date(v).toLocaleDateString('pt-BR', { timeZone: 'America/Sao_Paulo' }) : '');
const slugDe = (texto) => String(texto || '').normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase()
  .replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '').replace(/-{2,}/g, '-').slice(0, 28).replace(/-+$/, '');

function aviso(texto) {
  const t = $('#painelAviso');
  t.textContent = texto;
  t.classList.add('show');
  clearTimeout(aviso.relogio);
  aviso.relogio = setTimeout(() => t.classList.remove('show'), 2600);
}

function mostrarLogin(erro = '') {
  $('#painelApp').classList.add('hidden');
  $('#painelLogin').classList.remove('hidden');
  $('#painelSenha').value = '';
  $('#painelLoginErro').textContent = erro;
}

// Endereço de teste (site de teste, computador local): o link do convite abre a barbearia pelo
// ?barbearia= neste mesmo endereço. Nos endereços reais, o link usa o endereço da barbearia.
let enderecoDeTeste = null;
async function ehEnderecoDeTeste() {
  if (enderecoDeTeste !== null) return enderecoDeTeste;
  try {
    const r = await rpc('barberium_resolve_tenant', { p_host: location.hostname });
    enderecoDeTeste = r?.allow_tenant_param === true;
  } catch {
    enderecoDeTeste = false;
  }
  return enderecoDeTeste;
}

async function entrarNoPainel() {
  let quem;
  try {
    quem = await rpc('barberium_platform_whoami');
  } catch {
    limparSessao();
    mostrarLogin();
    return;
  }
  if (!quem?.is_admin) {
    limparSessao();
    mostrarLogin('Este login não é dono do Barberium.');
    return;
  }
  $('#painelLogin').classList.add('hidden');
  $('#painelApp').classList.remove('hidden');
  await carregarLista();
}

async function carregarLista() {
  const lista = $('#painelLista');
  try {
    const barbearias = await rpc('barberium_platform_barbershops');
    lista.innerHTML = barbearias.length ? barbearias.map(cartao).join('') : '<div class="empty">Nenhuma barbearia ainda.</div>';
    lista.querySelectorAll('[data-convite]').forEach((b) => { b.onclick = () => gerarConvite(b.dataset.convite, b); });
  } catch (e) {
    lista.innerHTML = `<div class="empty">${esc(e.message || 'Não foi possível carregar.')}</div>`;
  }
}

function cartao(b) {
  const enderecos = b.hosts.map((h) => `<a href="https://${esc(h)}/" target="_blank" rel="noopener">${esc(h)}</a>`).join('<br>') || '<p>Sem endereço</p>';
  const unidades = b.units.map((u) => [u.name, [u.city, u.state].filter(Boolean).join('/')].filter(Boolean).join(' · ')).join('; ');
  const gestores = b.managers.map((m) => `${esc(m.email)} (${m.role === 'owner' ? 'proprietário' : 'ADM'}${m.is_active ? '' : ', inativo'}) — ${m.last_sign_in_at ? `último acesso ${dataBR(m.last_sign_in_at)}` : 'ainda não entrou'}`).join('<br>');
  // Quem ainda não entrou recebe o convite; quem já entrou e esqueceu a senha recebe um link de senha nova.
  const convites = b.invites.map((i) =>
    `<button class="soft-btn" type="button" data-convite="${esc(i.id)}">${i.last_sign_in_at ? 'Link de senha nova' : 'Gerar link de convite'} para ${esc(i.full_name)}</button>`).join('');
  const ativa = b.status === 'active';
  return `<article class="painel-card">
    <div class="painel-card-topo"><h3>${esc(b.name)}</h3><span class="painel-status ${ativa ? '' : 'inativa'}">${ativa ? 'Ativa' : 'Fora do ar'}</span></div>
    <div>${enderecos}</div>
    <p>${esc(unidades || 'Sem unidade')} · ${b.staff_count} ${b.staff_count === 1 ? 'pessoa' : 'pessoas'} na equipe · desde ${dataBR(b.created_at)}</p>
    ${gestores ? `<p>${gestores}</p>` : ''}
    ${convites}
  </article>`;
}

async function gerarConvite(id, botao) {
  if (botao) { botao.disabled = true; botao.textContent = 'Gerando…'; }
  try {
    const c = await requisicao('/functions/v1/barberium-convite', { method: 'POST', body: JSON.stringify({ convite: id }) });
    await mostrarConvite(c);
    await carregarLista();
  } catch (e) {
    aviso(e.message || 'Não foi possível gerar o convite.');
    if (botao) { botao.disabled = false; botao.textContent = 'Tentar de novo'; }
  }
}

async function mostrarConvite(c, nova = false) {
  const teste = await ehEnderecoDeTeste();
  const base = teste ? `${location.origin}/equipe/?barbearia=${encodeURIComponent(c.slug)}&` : `https://${c.host}/equipe/?`;
  const link = `${base}convite=${encodeURIComponent(c.codigo)}&tipo=${encodeURIComponent(c.tipo)}`;
  const site = teste ? `${location.origin}/?barbearia=${encodeURIComponent(c.slug)}` : `https://${c.host}/`;
  const equipe = teste ? `${location.origin}/equipe/?barbearia=${encodeURIComponent(c.slug)}` : `https://${c.host}/equipe/`;
  const primeiro = c.nome.split(/\s+/)[0];
  const texto = `Olá, ${primeiro}! A ${c.barbearia} já está no Barberium.\n\n`
    + `Para ${c.tipo === 'invite' ? 'criar sua senha' : 'escolher uma senha nova'} e entrar na Área da Equipe, abra este link (ele vale uma vez só):\n${link}\n\n`
    + `Depois, a Área da Equipe fica em ${equipe}\nO site para os seus clientes é ${site}`;
  const whats = c.whatsapp ? `https://wa.me/${c.whatsapp}?text=${encodeURIComponent(texto)}` : `https://wa.me/?text=${encodeURIComponent(texto)}`;
  $('#painelJanelaTitulo').textContent = nova ? `${c.barbearia} cadastrada` : `Convite para ${c.nome}`;
  $('#painelJanelaCorpo').innerHTML = `
    <p>Mande o convite para <strong>${esc(c.nome)}</strong> (${esc(c.email)}). O link vale uma vez só e por pouco tempo; se vencer, gere outro aqui no painel.</p>
    <textarea id="painelTextoConvite" readonly>${esc(texto)}</textarea>
    <a class="gold-btn" href="${esc(whats)}" target="_blank" rel="noopener">Enviar pelo WhatsApp</a>
    <button id="painelCopiar" class="soft-btn" type="button">Copiar mensagem</button>
    ${teste ? '' : `<p class="painel-nota">O endereço ${esc(c.host)} entra no ar na próxima publicação de endereços (até 1 hora). Para agora, toque em <a href="${ACOES_ENDERECOS}" target="_blank" rel="noopener">Publicar endereços</a> → Run workflow. Mande o convite depois disso.</p>`}`;
  $('#painelCopiar').onclick = async () => {
    try { await navigator.clipboard.writeText(texto); aviso('Mensagem copiada.'); } catch { $('#painelTextoConvite').select(); aviso('Selecione e copie a mensagem.'); }
  };
  $('#painelJanela').classList.remove('hidden');
}

function abrirNova(abrir) {
  $('#painelNova').classList.toggle('hidden', !abrir);
  if (abrir) {
    $('#painelNovaForm').reset();
    $('#novaSlug').dataset.editado = '';
    $('#novaErro').textContent = '';
    $('#novaNome').focus();
  }
}

$('#painelLoginForm').addEventListener('submit', async (e) => {
  e.preventDefault();
  const botao = $('#painelEntrar');
  botao.disabled = true;
  botao.textContent = 'Entrando…';
  $('#painelLoginErro').textContent = '';
  try {
    limparSessao();
    const sessao = await requisicao('/auth/v1/token?grant_type=password', {
      method: 'POST', body: JSON.stringify({ email: $('#painelEmail').value.trim(), password: $('#painelSenha').value }),
    });
    salvarSessao(sessao);
    await entrarNoPainel();
  } catch (err) {
    $('#painelLoginErro').textContent = /invalid/i.test(err.message) ? 'E-mail ou senha incorretos.' : (err.message || 'Não foi possível entrar.');
  } finally {
    botao.disabled = false;
    botao.textContent = 'Entrar';
  }
});

$('#painelSair').onclick = async () => {
  try { await requisicao('/auth/v1/logout', { method: 'POST', body: '{}' }); } catch { /* sai mesmo assim */ }
  limparSessao();
  mostrarLogin();
};

$('#painelNovaBotao').onclick = () => abrirNova(true);
$('#novaCancelar').onclick = () => abrirNova(false);
$('#novaNome').addEventListener('input', () => { if (!$('#novaSlug').dataset.editado) $('#novaSlug').value = slugDe($('#novaNome').value); });
$('#novaSlug').addEventListener('input', () => {
  $('#novaSlug').dataset.editado = '1';
  const limpo = $('#novaSlug').value.toLowerCase().replace(/[^a-z0-9-]/g, '');
  if (limpo !== $('#novaSlug').value) $('#novaSlug').value = limpo;
});

$('#painelNovaForm').addEventListener('submit', async (e) => {
  e.preventDefault();
  const botao = $('#novaSalvar');
  botao.disabled = true;
  botao.textContent = 'Cadastrando…';
  $('#novaErro').textContent = '';
  let criada = null;
  try {
    criada = await rpc('barberium_platform_create_barbershop', {
      p_name: $('#novaNome').value, p_slug: $('#novaSlug').value, p_unit_name: $('#novaUnidade').value,
      p_city: $('#novaCidade').value, p_state: $('#novaUf').value, p_whatsapp: $('#novaWhats').value,
      p_admin_name: $('#novaAdmNome').value, p_admin_email: $('#novaAdmEmail').value, p_admin_whatsapp: $('#novaAdmWhats').value,
    });
    const c = await requisicao('/functions/v1/barberium-convite', { method: 'POST', body: JSON.stringify({ convite: criada.invite_id }) });
    abrirNova(false);
    await carregarLista();
    await mostrarConvite(c, true);
  } catch (err) {
    if (criada) {
      // A barbearia foi criada; só o convite falhou. Dá para gerar de novo pela lista.
      abrirNova(false);
      await carregarLista();
      aviso('Barbearia cadastrada, mas o convite falhou. Gere o link de novo na lista.');
    } else {
      $('#novaErro').textContent = err.message || 'Não foi possível cadastrar.';
    }
  } finally {
    botao.disabled = false;
    botao.textContent = 'Cadastrar e gerar convite';
  }
});

$('#painelJanelaFechar').onclick = () => $('#painelJanela').classList.add('hidden');

if (lerSessao()?.access_token) entrarNoPainel();
else mostrarLogin();
