// Barberium · primeiro acesso por convite (painel do dono do SaaS, 21/10/2026).
//
// O link do convite abre a Área da Equipe com ?convite=<código>&tipo=invite (ou recovery, quando
// o e-mail já tinha login). Esta tela troca o login pela criação da senha: confere o código no
// Supabase (ele vale uma vez só), grava a senha e entra. Depois disso, o acesso é o de sempre,
// com e-mail e senha, no endereço da barbearia.
//
// Roda antes do team.js: se este aparelho tinha outro login da equipe guardado, ele sai, para o
// convite abrir sempre a tela da senha.
import { SUPABASE_URL, SUPABASE_KEY } from '../shared/config.js?v=1';
import { salvarSessao, limparSessao } from '../shared/api.js?v=1';

const params = new URLSearchParams(location.search);
const codigo = params.get('convite') || '';
const tipo = params.get('tipo') || '';
const PRAZO = 30_000;
const LINK_INVALIDO = 'Este link venceu ou já foi usado. Peça um link novo para quem te convidou.';

async function chamar(caminho, { metodo = 'POST', corpo, token } = {}) {
  const resposta = await fetch(`${SUPABASE_URL}${caminho}`, {
    method: metodo,
    headers: { apikey: SUPABASE_KEY, 'Content-Type': 'application/json', ...(token ? { Authorization: `Bearer ${token}` } : {}) },
    body: JSON.stringify(corpo),
    signal: AbortSignal.timeout(PRAZO),
  });
  const texto = await resposta.text();
  let dados = null;
  try { dados = texto ? JSON.parse(texto) : null; } catch { dados = texto; }
  return { ok: resposta.ok, status: resposta.status, dados };
}

function mensagemDaSenha(dados) {
  const m = String(dados?.msg || dados?.message || dados?.error_description || '');
  if (/weak|at least|characters|caracteres/i.test(m)) return 'Senha fraca. Use pelo menos 8 caracteres, misturando letras e números.';
  if (/same|different from the old/i.test(m)) return 'Escolha uma senha diferente da anterior.';
  return 'Não foi possível salvar a senha agora. Tente de novo.';
}

function iniciar() {
  limparSessao();
  const view = document.getElementById('loginView');
  const login = document.getElementById('loginForm');
  if (!view || !login) return;
  login.hidden = true;
  login.style.display = 'none';
  const primeira = tipo === 'invite';
  const form = document.createElement('form');
  form.id = 'conviteForm';
  form.className = 'login-card';
  form.innerHTML = `
    <p style="margin:0;font:500 22px/1.15 var(--serif);text-align:center">${primeira ? 'Crie sua senha' : 'Escolha uma senha nova'}</p>
    <p style="margin:-6px 0 2px;font-size:12px;line-height:1.5;color:var(--muted);text-align:center">${primeira
      ? 'Este é o seu primeiro acesso. Depois, é só entrar com o seu e-mail e esta senha.'
      : 'Depois, é só entrar com o seu e-mail e esta senha.'}</p>
    <label>Senha nova
      <div class="password-wrap">
        <input id="conviteSenha" type="password" autocomplete="new-password" required placeholder="Pelo menos 8 caracteres">
        <button id="conviteVer" type="button">Ver</button>
      </div>
    </label>
    <label>Repita a senha
      <input id="conviteSenha2" type="password" autocomplete="new-password" required placeholder="A mesma senha">
    </label>
    <button class="gold-btn" id="conviteBotao" type="submit">Salvar senha e entrar</button>
    <p class="form-error" id="conviteErro"></p>`;
  login.after(form);
  const $ = (id) => document.getElementById(id);
  $('conviteVer').onclick = () => {
    const ver = $('conviteSenha').type === 'password';
    $('conviteSenha').type = ver ? 'text' : 'password';
    $('conviteSenha2').type = ver ? 'text' : 'password';
    $('conviteVer').textContent = ver ? 'Ocultar' : 'Ver';
  };

  // A sessão do convite fica só na memória até a senha ser salva: se a senha for recusada, dá
  // para tentar outra sem gastar o link de novo.
  let sessao = null;
  form.addEventListener('submit', async (e) => {
    e.preventDefault();
    const senha = $('conviteSenha').value;
    const erro = $('conviteErro');
    erro.textContent = '';
    if (senha.length < 8) { erro.textContent = 'Use pelo menos 8 caracteres.'; return; }
    if (senha !== $('conviteSenha2').value) { erro.textContent = 'As duas senhas não são iguais.'; return; }
    const botao = $('conviteBotao');
    botao.disabled = true;
    botao.textContent = 'Salvando…';
    try {
      if (!sessao) {
        const v = await chamar('/auth/v1/verify', { corpo: { type: tipo, token_hash: codigo } });
        if (!v.ok || !v.dados?.access_token) {
          erro.textContent = LINK_INVALIDO;
          botao.textContent = 'Link vencido';
          return;
        }
        sessao = v.dados;
      }
      const s = await chamar('/auth/v1/user', { metodo: 'PUT', corpo: { password: senha }, token: sessao.access_token });
      if (!s.ok) {
        erro.textContent = mensagemDaSenha(s.dados);
        botao.disabled = false;
        botao.textContent = 'Salvar senha e entrar';
        return;
      }
      salvarSessao(sessao);
      const url = new URL(location.href);
      url.searchParams.delete('convite');
      url.searchParams.delete('tipo');
      location.replace(url.toString());
    } catch {
      erro.textContent = 'A conexão falhou. Confira a internet e tente de novo.';
      botao.disabled = false;
      botao.textContent = 'Salvar senha e entrar';
    }
  });
}

if (codigo && /^[0-9a-f]{20,200}$/i.test(codigo) && (tipo === 'invite' || tipo === 'recovery')) iniciar();
