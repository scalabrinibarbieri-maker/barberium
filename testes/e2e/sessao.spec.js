// Etapa 5 · login compartilhado da Área da Equipe (shared/api.js). Não usa o site no ar: monta o
// site de teste, serve no próprio computador e simula o Supabase dentro do navegador, com o
// refresh token de uso único (cada renovação invalida o anterior, como no Supabase).
import { test, expect } from '@playwright/test';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, readFileSync, existsSync, statSync } from 'node:fs';
import { createServer } from 'node:http';
import { tmpdir } from 'node:os';
import { join, extname, normalize } from 'node:path';
import { fileURLToPath } from 'node:url';

const RAIZ_REPO = fileURLToPath(new URL('../..', import.meta.url));
const VERSAO = 'ddddddd';
const SUPABASE_TESTE = /STAGING_URL=(\S+)/.exec(readFileSync(join(RAIZ_REPO, 'supabase/staging/projeto.env'), 'utf8'))[1];
const TIPOS = { '.html': 'text/html; charset=utf-8', '.js': 'application/javascript', '.css': 'text/css', '.json': 'application/json' };

test.describe.configure({ mode: 'serial' });

let servidor, base, pasta;
test.beforeAll(async () => {
  pasta = join(mkdtempSync(join(tmpdir(), 'barberium-sessao-')), 'site');
  execFileSync('bash', [join(RAIZ_REPO, 'deploy/montar_site.sh'), pasta, 'teste'], { env: { ...process.env, VERSAO_SITE: VERSAO }, stdio: 'pipe' });
  servidor = createServer((req, res) => {
    const caminho = decodeURIComponent(new URL(req.url, 'http://x').pathname);
    let arquivo = normalize(join(pasta, caminho.endsWith('/') ? caminho + 'index.html' : caminho));
    if (!arquivo.startsWith(pasta) || !existsSync(arquivo) || statSync(arquivo).isDirectory()) arquivo = join(pasta, 'index.html');
    res.writeHead(200, { 'Content-Type': TIPOS[extname(arquivo)] || 'application/octet-stream' });
    res.end(readFileSync(arquivo));
  });
  await new Promise((ok) => servidor.listen(0, '127.0.0.1', ok));
  base = `http://127.0.0.1:${servidor.address().port}`;
});
test.afterAll(async () => { await new Promise((ok) => servidor.close(ok)); });

// Supabase simulado: tokens de acesso válidos, refresh tokens de uso único e contadores.
function supabaseFalso() {
  const estado = { validos: new Set(), refresh: new Map(), renovacoes: 0, recusadas: 0, n: 0, atrasoMs: 150, respostaRpc: null, penduradas: [] };
  estado.novaSessao = () => {
    estado.n += 1;
    const s = { access_token: `acesso-${estado.n}`, refresh_token: `refresh-${estado.n}`, token_type: 'bearer', expires_in: 3600, expires_at: Math.floor(Date.now() / 1000) + 3600 };
    estado.validos.add(s.access_token);
    estado.refresh.set(s.refresh_token, true);
    return s;
  };
  estado.rota = async (route) => {
    const req = route.request();
    const url = new URL(req.url());
    const json = (status, corpo) => route.fulfill({ status, contentType: 'application/json', headers: { 'Access-Control-Allow-Origin': '*' }, body: corpo === undefined ? '' : JSON.stringify(corpo) });
    if (req.method() === 'OPTIONS') return route.fulfill({ status: 204, headers: { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': '*', 'Access-Control-Allow-Methods': '*' } });
    if (url.pathname === '/auth/v1/token') {
      const { refresh_token: r } = JSON.parse(req.postData() || '{}');
      await new Promise((ok) => setTimeout(ok, 50));
      if (!estado.refresh.get(r)) { estado.recusadas += 1; return json(400, { error: 'invalid_grant', error_description: 'Invalid Refresh Token: Already Used' }); }
      estado.refresh.set(r, false);
      estado.renovacoes += 1;
      return json(200, estado.novaSessao());
    }
    const nome = url.pathname.replace('/rest/v1/rpc/', '');
    if (nome === 'lenta') return new Promise((ok) => estado.penduradas.push(ok)); // nunca responde
    await new Promise((ok) => setTimeout(ok, estado.atrasoMs));
    const token = (req.headers().authorization || '').replace('Bearer ', '');
    if (!estado.validos.has(token)) return json(401, { code: 'PGRST303', message: 'JWT expired' });
    if (estado.respostaRpc) return json(estado.respostaRpc.status, estado.respostaRpc.corpo);
    return json(200, { ok: true, rpc: nome, token });
  };
  return estado;
}

async function abrir(context, sessao) {
  const page = await context.newPage();
  await page.goto(`${base}/versao.json`);
  await page.evaluate(([s]) => { if (s) localStorage.setItem('barberium_staff_auth_v1', JSON.stringify(s)); else localStorage.removeItem('barberium_staff_auth_v1'); }, [sessao]);
  await page.evaluate(async (v) => { window.api = await import(`/shared/api.js?v=${v}`); }, VERSAO);
  return page;
}
const vencida = (estado) => {
  const s = estado.novaSessao();
  estado.validos.delete(s.access_token); // o acesso venceu; o refresh ainda vale
  return s;
};

test('várias chamadas ao mesmo tempo com o login vencido: renova uma vez só e todas funcionam', async ({ context }) => {
  const sb = supabaseFalso();
  await context.route(`${SUPABASE_TESTE}/**`, sb.rota);
  const page = await abrir(context, vencida(sb));
  const r = await page.evaluate(async () => {
    const a = window.api.criarCliente(), b = window.api.criarCliente(), c = window.api.criarCliente();
    const todas = await Promise.all([a, b, c, a, b, c, a, b].map((cli, i) => cli.rpc(`chamada_${i}`)));
    return { ok: todas.every((x) => x.ok), guardada: JSON.parse(localStorage.getItem('barberium_staff_auth_v1')).access_token };
  });
  expect(r.ok).toBe(true);
  expect(sb.renovacoes).toBe(1);
  expect(sb.recusadas).toBe(0);
  expect(r.guardada).toBe('acesso-2');
});

test('duas abas com o login vencido ao mesmo tempo: uma renovação só no aparelho', async ({ context }) => {
  const sb = supabaseFalso();
  await context.route(`${SUPABASE_TESTE}/**`, sb.rota);
  const sessao = vencida(sb);
  const [aba1, aba2] = [await abrir(context, sessao), await abrir(context, sessao)];
  const chamar = (p) => p.evaluate(async () => { const c = window.api.criarCliente(); return (await Promise.all([1, 2, 3].map((i) => c.rpc(`aba_${i}`)))).every((x) => x.ok); });
  const [ok1, ok2] = await Promise.all([chamar(aba1), chamar(aba2)]);
  expect(ok1 && ok2).toBe(true);
  expect(sb.renovacoes).toBe(1);
  expect(sb.recusadas).toBe(0);
});

test('se outra aba já renovou o login, não renova de novo: usa o login novo', async ({ context }) => {
  const sb = supabaseFalso();
  sb.atrasoMs = 400;
  await context.route(`${SUPABASE_TESTE}/**`, sb.rota);
  const velha = vencida(sb);
  const nova = sb.novaSessao();
  const page = await abrir(context, velha);
  const chamada = page.evaluate(() => window.api.criarCliente().rpc('depois_da_outra_aba'));
  await page.waitForTimeout(100); // a chamada já saiu com o login velho
  await page.evaluate((s) => localStorage.setItem('barberium_staff_auth_v1', JSON.stringify(s)), nova);
  const r = await chamada;
  expect(r.ok).toBe(true);
  expect(r.token).toBe(nova.access_token);
  expect(sb.renovacoes).toBe(0);
});

test('refresh recusado: o erro tem a mesma mensagem de antes e não tenta de novo', async ({ context }) => {
  const sb = supabaseFalso();
  await context.route(`${SUPABASE_TESTE}/**`, sb.rota);
  const s = vencida(sb);
  sb.refresh.set(s.refresh_token, false); // já usado
  const page = await abrir(context, s);
  const r = await page.evaluate(async () => {
    const c = window.api.criarCliente();
    const pegar = (p) => p.then(() => null, (e) => ({ texto: String(e), status: e.status, codigo: e.codigo }));
    return [await pegar(c.rpc('primeira')), await pegar(c.rpc('segunda'))];
  });
  expect(r[0]).toEqual({ texto: 'Error: JWT expired', status: 401, codigo: 'PGRST303' });
  expect(r[1].texto).toBe('Error: JWT expired');
  expect(sb.recusadas).toBe(1);
});

test('sem login: chama sem token e não tenta renovar', async ({ context }) => {
  const sb = supabaseFalso();
  const autorizacoes = [];
  await context.route(`${SUPABASE_TESTE}/**`, (route) => { autorizacoes.push(route.request().headers().authorization || ''); return sb.rota(route); });
  const page = await abrir(context, null);
  const r = await page.evaluate(() => window.api.criarCliente().rpc('qualquer').then(() => 'ok', (e) => e.message));
  expect(r).toBe('JWT expired');
  expect(autorizacoes).toEqual(['']);
  expect(sb.renovacoes + sb.recusadas).toBe(0);
});

test('erros guardam a mensagem de antes e ganham status e código', async ({ context }) => {
  const sb = supabaseFalso();
  await context.route(`${SUPABASE_TESTE}/**`, sb.rota);
  const page = await abrir(context, sb.novaSessao());
  const casos = [
    [{ status: 400, corpo: { code: 'P0001', message: 'Sem permissão' } }, 'Sem permissão', 'P0001'],
    [{ status: 400, corpo: { msg: 'Mensagem do login' } }, 'Mensagem do login', null],
    [{ status: 400, corpo: { error: 'x', error_description: 'Descrição' } }, 'Descrição', null],
    [{ status: 403, corpo: { error: 'proibido' } }, 'proibido', null],
    [{ status: 500, corpo: undefined }, 'Erro 500', null],
  ];
  for (const [resposta, mensagem, codigo] of casos) {
    sb.respostaRpc = resposta;
    const r = await page.evaluate(() => window.api.criarCliente().rpc('com_erro').then(() => null, (e) => ({ m: e.message, s: e.status, c: e.codigo, nome: e.name })));
    expect(r).toEqual({ m: mensagem, s: resposta.status, c: codigo, nome: 'Error' });
  }
});

test('o módulo pode manter o próprio fetch (alguns usam o original, antes dos interceptadores)', async ({ context }) => {
  const sb = supabaseFalso();
  await context.route(`${SUPABASE_TESTE}/**`, sb.rota);
  const page = await abrir(context, vencida(sb));
  const r = await page.evaluate(async () => {
    let usos = 0;
    const meu = (u, i) => { usos += 1; return fetch(u, i); };
    const res = await window.api.criarCliente({ transporte: meu }).rpc('com_transporte');
    return { ok: res.ok, usos };
  });
  expect(r).toEqual({ ok: true, usos: 3 }); // chamada com 401, renovação e nova chamada
});

test('chamada que não responde termina em 30 s com uma mensagem clara', async ({ context }) => {
  const sb = supabaseFalso();
  await context.route(`${SUPABASE_TESTE}/**`, sb.rota);
  const page = await context.newPage();
  await page.clock.install();
  await page.goto(`${base}/versao.json`);
  await page.evaluate((s) => localStorage.setItem('barberium_staff_auth_v1', JSON.stringify(s)), sb.novaSessao());
  await page.evaluate(async (v) => {
    const api = await import(`/shared/api.js?v=${v}`);
    window.resultado = null;
    api.criarCliente().rpc('lenta').then(() => { window.resultado = 'respondeu'; }, (e) => { window.resultado = { m: e.message, c: e.codigo }; });
  }, VERSAO);
  await page.clock.fastForward(29_000);
  expect(await page.evaluate(() => window.resultado)).toBe(null);
  await page.clock.fastForward(2_000);
  await expect.poll(() => page.evaluate(() => window.resultado)).toEqual({ m: 'A conexão demorou demais. Confira a internet e tente de novo.', c: 'TEMPO_ESGOTADO' });
  sb.penduradas.forEach((ok) => ok());
});
