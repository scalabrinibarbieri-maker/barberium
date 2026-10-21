// Barberium · chamadas da Área da Equipe ao Supabase (etapa 5, 20/10/2026).
//
// Antes, cada módulo da Área da Equipe tinha a própria cópia deste código (14 ao todo). Cada
// cópia renovava o login sozinha quando recebia "401". Com o token vencido e vários módulos
// chamando juntos, todos tentavam renovar com o mesmo refresh token; o Supabase troca esse
// token a cada renovação, então parte delas falhava e o login caía.
//
// Agora existe uma sessão só:
//   - uma renovação por vez, no aparelho todo (inclusive entre abas, quando o navegador permite);
//   - antes de renovar, relê o login guardado: se outro módulo ou aba já renovou, usa o novo;
//   - refresh token recusado não é tentado de novo;
//   - toda chamada tem prazo (30 s; 120 s para envio de fotos) e o erro traz status e código.
// A mensagem dos erros é a mesma de antes, então as telas mostram o mesmo texto.
//
// Etapa 6: toda chamada ao banco diz de qual barbearia é a Área da Equipe aberta (cabeçalho
// x-barberium-barbearia, com a barbearia do endereço do site, de shared/tenant.js). Um login
// que é da equipe de duas barbearias entra em cada uma pelo endereço dela.
import { SUPABASE_URL, SUPABASE_KEY, CHAVE_SESSAO_EQUIPE } from './config.js?v=1';

const PRAZO_PADRAO = 30_000;
const PRAZO_ARQUIVOS = 120_000;
const MENSAGEM_PRAZO = 'A conexão demorou demais. Confira a internet e tente de novo.';

// Por padrão usa o window.fetch do momento da chamada, como as cópias antigas: assim os
// módulos que interceptam o fetch continuam vendo as chamadas exatamente como antes.
const transportePadrao = (url, init) => window.fetch(url, init);

// Erro comum (Error) com a mesma mensagem de antes, mais status HTTP, código e a resposta.
// Não é uma subclasse de propósito: o console e quem mostra String(erro) veem o mesmo de antes.
export function erroApi(mensagem, { status = 0, codigo = null, dados = null } = {}) {
  return Object.assign(new Error(mensagem), { status, codigo, dados });
}

export function lerSessao() {
  try { return JSON.parse(localStorage.getItem(CHAVE_SESSAO_EQUIPE) || 'null'); } catch { return null; }
}
export function salvarSessao(sessao) {
  localStorage.setItem(CHAVE_SESSAO_EQUIPE, JSON.stringify(sessao));
}
export function limparSessao() {
  localStorage.removeItem(CHAVE_SESSAO_EQUIPE);
}

function mensagemDeErro(dados, status) {
  return dados?.message || dados?.msg || dados?.error_description || dados?.error || `Erro ${status}`;
}

// Faz a chamada e lê a resposta inteira dentro do prazo.
async function buscar(transporte, url, init, prazo) {
  const controle = new AbortController();
  const externo = init.signal;
  if (externo) {
    if (externo.aborted) controle.abort(externo.reason);
    else externo.addEventListener('abort', () => controle.abort(externo.reason), { once: true });
  }
  let estourou = false;
  const relogio = setTimeout(() => { estourou = true; controle.abort(); }, prazo);
  try {
    const resposta = await transporte(url, { ...init, signal: controle.signal });
    const texto = await resposta.text();
    return { resposta, texto };
  } catch (erro) {
    if (estourou) throw erroApi(MENSAGEM_PRAZO, { codigo: 'TEMPO_ESGOTADO' });
    throw erro;
  } finally {
    clearTimeout(relogio);
  }
}

let renovacaoEmAndamento = null;
const refreshRecusados = new Set();

// Renova o login. "usada" é a sessão com que a chamada recebeu 401: se o login guardado já é
// outro, alguém renovou antes e basta usar o guardado. Devolve a sessão nova, ou null.
export function renovarSessao({ transporte = transportePadrao, usada = lerSessao() } = {}) {
  if (renovacaoEmAndamento) return renovacaoEmAndamento;
  const executar = async () => {
    const atual = lerSessao();
    if (atual?.access_token && usada?.access_token && atual.access_token !== usada.access_token) return atual;
    if (!atual?.refresh_token || refreshRecusados.has(atual.refresh_token)) return null;
    const { resposta, texto } = await buscar(transporte, `${SUPABASE_URL}/auth/v1/token?grant_type=refresh_token`, {
      method: 'POST',
      headers: { apikey: SUPABASE_KEY, 'Content-Type': 'application/json' },
      body: JSON.stringify({ refresh_token: atual.refresh_token }),
    }, PRAZO_PADRAO);
    if (!resposta.ok) {
      refreshRecusados.add(atual.refresh_token);
      const depois = lerSessao();
      return depois?.refresh_token && depois.refresh_token !== atual.refresh_token ? depois : null;
    }
    const nova = JSON.parse(texto);
    salvarSessao(nova);
    return nova;
  };
  renovacaoEmAndamento = (async () => {
    try {
      if (navigator.locks?.request) return await navigator.locks.request('barberium-sessao-equipe', executar);
      return await executar();
    } catch {
      return null; // sem internet ou prazo esgotado na renovação: a chamada segue com o 401
    } finally {
      renovacaoEmAndamento = null;
    }
  })();
  return renovacaoEmAndamento;
}

// Barbearia do endereço do site, para as chamadas ao banco (/rest/). Sem o shared/tenant.js na
// página, não manda nada, e o banco usa o único vínculo do login, como antes da etapa 6.
async function barbeariaDoEndereco(caminho) {
  if (!caminho.startsWith('/rest/') || !window.barberiumTenantPronto) return null;
  return (await window.barberiumTenantPronto).barbershopSlug;
}

// Cria as funções de chamada de um módulo. "transporte" é o fetch que o módulo usava antes
// (alguns usam uma cópia do fetch guardada antes dos interceptadores, de propósito).
export function criarCliente({ transporte = transportePadrao } = {}) {
  async function requisicao(caminho, opcoes = {}) {
    const prazo = caminho.startsWith('/storage/') ? PRAZO_ARQUIVOS : PRAZO_PADRAO;
    const barbearia = await barbeariaDoEndereco(caminho);
    const sessao = lerSessao();
    const headers = { apikey: SUPABASE_KEY, 'Content-Type': 'application/json', ...(opcoes.headers || {}) };
    if (barbearia) headers['x-barberium-barbearia'] = barbearia;
    if (sessao?.access_token) headers.Authorization = `Bearer ${sessao.access_token}`;
    let { resposta, texto } = await buscar(transporte, `${SUPABASE_URL}${caminho}`, { ...opcoes, headers }, prazo);
    if (resposta.status === 401 && sessao?.refresh_token) {
      const nova = await renovarSessao({ transporte, usada: sessao });
      if (nova?.access_token) {
        headers.Authorization = `Bearer ${nova.access_token}`;
        ({ resposta, texto } = await buscar(transporte, `${SUPABASE_URL}${caminho}`, { ...opcoes, headers }, prazo));
      }
    }
    let dados = null;
    try { dados = texto ? JSON.parse(texto) : null; } catch { dados = texto; }
    if (!resposta.ok) {
      throw erroApi(mensagemDeErro(dados, resposta.status), {
        status: resposta.status,
        codigo: (dados && typeof dados === 'object' && (dados.code || dados.error_code)) || null,
        dados,
      });
    }
    return dados;
  }
  const rpc = (nome, parametros = {}) => requisicao(`/rest/v1/rpc/${nome}`, { method: 'POST', body: JSON.stringify(parametros) });
  return { requisicao, rpc };
}
