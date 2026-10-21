// Barberium · de qual barbearia é este site (etapa 6, 21/10/2026).
//
// O site pergunta ao banco, pelo endereço em que foi aberto (scalabrinibarbiere.com, por
// exemplo), de qual barbearia ele é e em qual unidade. Antes, "scalabrini-barbieri" e
// "braganca-paulista" estavam escritos em cada arquivo do site.
//
//   - Endereço com unidade fixa: abre direto nela (é o caso da Scalabrini hoje).
//   - Sem unidade fixa e com mais de uma unidade: o site do cliente pede para escolher. A
//     escolha fica guardada no aparelho e pode ser trocada em "Trocar unidade".
//   - Endereços de teste (site de teste, computador local) aceitam ?barbearia=slug. Quem decide
//     se o endereço aceita é o banco; nos endereços reais o parâmetro é ignorado.
//   - Endereço não cadastrado ou sem internet: aviso na tela, e o site não abre.
//
// Uso nos módulos:        import { tenantPronto } (deste arquivo, com ?v=1 como os outros)
// Nos scripts comuns:     window.barberiumTenantPronto
// As duas promessas só terminam quando a barbearia (e, no site do cliente, a unidade) está
// definida. A partir daí, window.BARBERIUM_TENANT tem os mesmos dados. Se o site não puder
// abrir, elas nunca terminam: o aviso fica na tela e nada mais roda.
import { SUPABASE_URL, SUPABASE_KEY } from './config.js?v=1';

const AREA = /\/equipe(\/|$)/.test(location.pathname) ? 'equipe' : 'cliente';
const PRAZO = 20_000;
const CHAVE_BARBEARIA_TESTE = 'barberium:barbearia-de-teste'; // sessionStorage, só endereços de teste
// Login do cliente guardado no aparelho: um por barbearia. A Scalabrini mantém o nome de antes
// da etapa 6, para nenhum cliente ser desconectado.
const SESSAO_DE_ANTES = { 'scalabrini-barbieri': 'barberium_scalabrini_session_v1' };

const ler = (armazem, chave) => { try { return armazem.getItem(chave); } catch { return null; } };
const gravar = (armazem, chave, valor) => {
  try { if (valor == null) armazem.removeItem(chave); else armazem.setItem(chave, valor); } catch { /* aparelho sem armazenamento */ }
};
const parametro = (nome) => (new URLSearchParams(location.search).get(nome) || '').trim().toLowerCase() || null;
// Unidade escolhida pelo cliente, por endereço (e, nos endereços de teste, por barbearia).
const chaveUnidade = (barbearia) => `barberium:unidade:${location.hostname}:${barbearia || ''}`;
let chaveDaUnidadeEscolhida = null;
const esc = (v) => String(v ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#039;' }[c]));

function falha(tipo, mensagem) {
  return Object.assign(new Error(mensagem), { tipo });
}

async function perguntar(barbearia, unidade) {
  const controle = new AbortController();
  const relogio = setTimeout(() => controle.abort(), PRAZO);
  try {
    const resposta = await fetch(`${SUPABASE_URL}/rest/v1/rpc/barberium_resolve_tenant`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', apikey: SUPABASE_KEY, Authorization: `Bearer ${SUPABASE_KEY}` },
      body: JSON.stringify({ p_host: location.hostname, p_barbershop_slug: barbearia, p_unit_slug: unidade }),
      signal: controle.signal,
    });
    const texto = await resposta.text();
    let dados = null;
    try { dados = texto ? JSON.parse(texto) : null; } catch { dados = texto; }
    if (!resposta.ok) {
      const naoCadastrado = dados?.message === 'TENANT_NOT_FOUND';
      throw falha(naoCadastrado ? 'nao-cadastrado' : 'sem-conexao', dados?.message || `Erro ${resposta.status}`);
    }
    return dados;
  } catch (erro) {
    throw erro.tipo ? erro : falha('sem-conexao', erro.message);
  } finally {
    clearTimeout(relogio);
  }
}

function montar(r, unidade) {
  const slug = r.barbershop.slug;
  return Object.freeze({
    host: r.host,
    barbershopSlug: slug,
    barbershopName: r.barbershop.name,
    timezone: r.barbershop.timezone,
    unitSlug: unidade?.slug || null,
    unitName: unidade?.name || null,
    unitFixed: r.unit_fixed === true,
    units: Object.freeze([...(r.units || [])]),
    logoUrl: r.logo_url || null,
    enderecoDeTeste: r.allow_tenant_param === true,
    chaveSessaoCliente: SESSAO_DE_ANTES[slug] || `barberium_cliente_${slug}_v1`,
  });
}

async function resolver() {
  const pedidaNaUrl = parametro('barbearia');
  let barbearia = pedidaNaUrl || ler(sessionStorage, CHAVE_BARBEARIA_TESTE);
  const unidadeNaUrl = parametro('unidade');
  const unidadeGuardada = () => ler(localStorage, chaveUnidade(barbearia));
  let r;
  try {
    r = await perguntar(barbearia, AREA === 'cliente' ? (unidadeNaUrl || unidadeGuardada()) : null);
  } catch (erro) {
    // A barbearia de teste guardada nesta aba pode ter saído do ar: tenta o endereço puro.
    if (erro.tipo !== 'nao-cadastrado' || pedidaNaUrl || !barbearia) throw erro;
    gravar(sessionStorage, CHAVE_BARBEARIA_TESTE, null);
    barbearia = null;
    r = await perguntar(null, AREA === 'cliente' ? (unidadeNaUrl || unidadeGuardada()) : null);
  }
  gravar(sessionStorage, CHAVE_BARBEARIA_TESTE, r.allow_tenant_param && barbearia ? barbearia : null);
  if (!r.allow_tenant_param) barbearia = null;
  chaveDaUnidadeEscolhida = chaveUnidade(barbearia);

  if (AREA === 'equipe') return montar(r, r.unit);

  if (r.unit) {
    if (!r.unit_fixed) gravar(localStorage, chaveDaUnidadeEscolhida, r.unit.slug);
    return montar(r, r.unit);
  }
  const unidades = r.units || [];
  if (unidades.length === 0) throw falha('sem-unidade', 'Barbearia sem unidade ativa');
  if (unidades.length === 1) return montar(r, unidades[0]);
  const escolhida = await escolherUnidade(r);
  gravar(localStorage, chaveDaUnidadeEscolhida, escolhida.slug);
  return montar(r, escolhida);
}

// ---------- Telas ----------

function estilos() {
  if (document.getElementById('barberiumTenantEstilos')) return;
  const style = document.createElement('style');
  style.id = 'barberiumTenantEstilos';
  style.textContent = `
    #barberiumTenantTela{position:fixed;inset:0;z-index:10000;display:grid;place-items:center;overflow:auto;
      padding:calc(34px + env(safe-area-inset-top)) 22px calc(34px + env(safe-area-inset-bottom));
      background:radial-gradient(circle at 50% 22%,rgba(202,160,73,.09),transparent 31%),#020704;color:#f3ead7;text-align:center;
      font:500 15px/1.6 system-ui,-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif}
    #barberiumTenantTela .bt-card{width:min(100%,460px);display:flex;flex-direction:column;align-items:center}
    #barberiumTenantTela .bt-logo{width:92px;height:92px;object-fit:contain;margin-bottom:22px}
    #barberiumTenantTela .bt-linha{width:58px;height:1px;margin:0 auto 22px;background:linear-gradient(90deg,transparent,#dfb95f,transparent)}
    #barberiumTenantTela .bt-kicker{margin:0 0 10px;color:#d6ae5b;font-size:11px;font-weight:800;letter-spacing:.2em;text-transform:uppercase}
    #barberiumTenantTela h1{margin:0;font-family:Georgia,"Times New Roman",serif;font-size:clamp(30px,8vw,44px);line-height:1.05;font-weight:700;letter-spacing:-.02em}
    #barberiumTenantTela .bt-texto{max-width:400px;margin:18px auto 0;color:#aea692}
    #barberiumTenantTela .bt-lista{width:100%;display:grid;gap:10px;margin-top:28px}
    #barberiumTenantTela .bt-unidade{width:100%;display:flex;flex-direction:column;align-items:flex-start;gap:3px;padding:17px 18px;
      border:1px solid rgba(226,186,99,.26);border-radius:16px;background:rgba(255,255,255,.035);color:#f3ead7;text-align:left;cursor:pointer;font:inherit}
    #barberiumTenantTela .bt-unidade strong{font-size:16px;font-weight:750}
    #barberiumTenantTela .bt-unidade small{color:#a7a08f;font-size:12px;letter-spacing:.04em}
    #barberiumTenantTela .bt-unidade:hover,#barberiumTenantTela .bt-unidade:focus-visible{border-color:#d6ae5b;background:rgba(214,174,91,.08);outline:none}
    #barberiumTenantTela .bt-botao{margin-top:28px;min-height:50px;padding:0 26px;border:0;border-radius:15px;
      background:linear-gradient(135deg,#d6ae5b,#e5c477);color:#102016;font:800 14px/1 system-ui,-apple-system,sans-serif;cursor:pointer}
    #barberiumTenantTela .bt-rodape{margin-top:34px;color:#49473f;font-size:10px;font-weight:600;letter-spacing:.07em}
    .barberium-trocar-unidade{width:100%;margin-top:9px;cursor:pointer}
    @media(min-width:900px){.barberium-trocar-unidade{max-width:590px}}
  `;
  document.head.appendChild(style);
}

function tela(html) {
  estilos();
  let el = document.getElementById('barberiumTenantTela');
  if (!el) {
    el = document.createElement('section');
    el.id = 'barberiumTenantTela';
    document.body.appendChild(el);
  }
  el.innerHTML = `<div class="bt-card">${html}<p class="bt-rodape">Barberium</p></div>`;
  return el;
}

function escolherUnidade(r) {
  return new Promise((escolher) => {
    const logo = r.logo_url ? `<img class="bt-logo" src="${esc(r.logo_url)}" alt="">` : '';
    const el = tela(`${logo}<div class="bt-linha"></div><p class="bt-kicker">${esc(r.barbershop.name)}</p>
      <h1 id="btTitulo">Escolha a unidade</h1>
      <div class="bt-lista">${r.units.map((u, i) => `<button class="bt-unidade" type="button" data-unidade="${i}">
        <strong>${esc(u.name)}</strong><small>${esc([u.city, u.state].filter(Boolean).join(' • '))}</small></button>`).join('')}</div>`);
    el.setAttribute('role', 'dialog');
    el.setAttribute('aria-modal', 'true');
    el.setAttribute('aria-labelledby', 'btTitulo');
    el.addEventListener('click', (e) => {
      const botao = e.target.closest('[data-unidade]');
      if (!botao) return;
      // Até a marca da unidade escolhida aparecer, volta a tela de abertura (sem o site por trás).
      document.documentElement.classList.add('barberium-splash-pending');
      clearTimeout(window.__barberiumSplashFallbackTimer);
      window.__barberiumSplashFallbackTimer = setTimeout(() => document.documentElement.classList.remove('barberium-splash-pending'), 2200);
      el.remove();
      escolher(r.units[Number(botao.dataset.unidade)]);
    });
  });
}

const AVISOS = {
  'nao-cadastrado': ['Endereço não encontrado', 'Este endereço não está ligado a nenhuma barbearia.', false],
  'sem-unidade': ['Em breve', 'Esta barbearia ainda não tem unidade aberta para agendamento.', false],
  'sem-conexao': ['Sem conexão', 'Não foi possível abrir agora. Confira a internet e tente de novo.', true],
};

function mostrarAviso(tipo) {
  const [titulo, texto, tentar] = AVISOS[tipo] || AVISOS['sem-conexao'];
  const el = tela(`<div class="bt-linha"></div><h1>${esc(titulo)}</h1><p class="bt-texto">${esc(texto)}</p>
    ${tentar ? '<button class="bt-botao" type="button" data-tentar>Tentar de novo</button>' : ''}`);
  el.setAttribute('role', 'alert');
  el.querySelector('[data-tentar]')?.addEventListener('click', () => location.reload());
}

// "Trocar unidade" no cartão da unidade, quando o endereço não fixa a unidade.
function botaoTrocarUnidade(t) {
  if (AREA !== 'cliente' || t.unitFixed || t.units.length < 2) return;
  const lugar = document.querySelector('.unit-actions');
  if (!lugar || document.querySelector('.barberium-trocar-unidade')) return;
  estilos();
  const botao = document.createElement('button');
  botao.type = 'button';
  botao.className = 'outline-button barberium-trocar-unidade';
  botao.innerHTML = '<span class="button-icon">⇄</span> Trocar unidade';
  botao.addEventListener('click', trocarUnidade);
  lugar.after(botao);
}

export function trocarUnidade() {
  if (chaveDaUnidadeEscolhida) gravar(localStorage, chaveDaUnidadeEscolhida, null);
  const url = new URL(location.href);
  url.searchParams.delete('unidade');
  location.replace(url.toString());
}

export const tenantPronto = new Promise((pronto) => {
  resolver().then((t) => {
    window.BARBERIUM_TENANT = t;
    if (AREA === 'cliente' && t.logoUrl) document.getElementById('barberiumSplashLogo')?.setAttribute('src', t.logoUrl);
    botaoTrocarUnidade(t);
    pronto(t);
  }).catch((erro) => {
    (erro.tipo === 'sem-conexao' ? console.error : console.warn)('Barberium: endereço do site', erro.message);
    mostrarAviso(erro.tipo);
  });
});
window.barberiumTenantPronto = tenantPronto;
