// Etapa 4 · troca de versão. Não usa o site no ar: monta duas versões do site de teste
// (aaaaaaa e bbbbbbb) com deploy/montar_site.sh e serve no próprio computador, para simular
// uma publicação acontecendo com o site aberto num celular.
import { test, expect } from '@playwright/test';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, readFileSync, existsSync, statSync } from 'node:fs';
import { createServer } from 'node:http';
import { tmpdir } from 'node:os';
import { join, extname, normalize } from 'node:path';
import { fileURLToPath } from 'node:url';

const RAIZ_REPO = fileURLToPath(new URL('../..', import.meta.url));
const SW_ANTIGO = fileURLToPath(new URL('./fixtures/sw-antes-da-etapa4.js', import.meta.url));
const TIPOS = { '.html': 'text/html; charset=utf-8', '.js': 'application/javascript', '.css': 'text/css',
  '.json': 'application/json', '.webp': 'image/webp', '.svg': 'image/svg+xml', '.webmanifest': 'application/manifest+json' };

test.use({ serviceWorkers: 'allow' });
test.describe.configure({ mode: 'serial' });

let servidor, base;
const site = { pasta: '', swAntigo: false, versaoJson: null };
const builds = {};

function montar(versao) {
  const pasta = mkdtempSync(join(tmpdir(), `barberium-${versao}-`));
  execFileSync('bash', [join(RAIZ_REPO, 'deploy/montar_site.sh'), join(pasta, 'site'), 'teste'],
    { env: { ...process.env, VERSAO_SITE: versao }, stdio: 'pipe' });
  return join(pasta, 'site');
}

// Servidor parecido com o Cloudflare Pages: "/" e "/equipe/" viram index.html, e arquivo que não
// existe devolve a página inicial com status 200 (o modo SPA que o Cloudflare usa no site).
function servir(req, res) {
  const caminho = decodeURIComponent(new URL(req.url, 'http://x').pathname);
  if (caminho === '/sw.js' && site.swAntigo) {
    res.writeHead(200, { 'Content-Type': TIPOS['.js'], 'Cache-Control': 'no-cache' });
    return res.end(readFileSync(SW_ANTIGO));
  }
  if (caminho === '/versao.json' && site.versaoJson) {
    res.writeHead(200, { 'Content-Type': TIPOS['.json'], 'Cache-Control': 'no-store' });
    return res.end(JSON.stringify({ versao: site.versaoJson }));
  }
  let arquivo = normalize(join(site.pasta, caminho.endsWith('/') ? caminho + 'index.html' : caminho));
  if (!arquivo.startsWith(site.pasta) || !existsSync(arquivo) || statSync(arquivo).isDirectory()) arquivo = join(site.pasta, 'index.html');
  res.writeHead(200, { 'Content-Type': TIPOS[extname(arquivo)] || 'application/octet-stream', 'Cache-Control': 'no-cache' });
  res.end(readFileSync(arquivo));
}

test.beforeAll(async () => {
  builds.a = montar('aaaaaaa');
  builds.b = montar('bbbbbbb');
  servidor = createServer(servir);
  await new Promise((ok) => servidor.listen(0, '127.0.0.1', ok));
  base = `http://127.0.0.1:${servidor.address().port}`;
});
test.afterAll(async () => { await new Promise((ok) => servidor.close(ok)); });
test.beforeEach(() => { site.pasta = builds.a; site.swAntigo = false; site.versaoJson = null; });

const versaoDaPagina = (page) => page.locator('meta[name="barberium-versao"]').getAttribute('content');
const caches = (page) => page.evaluate(async () => (await self.caches.keys()).sort());
const registros = (page) => page.evaluate(async () => (await navigator.serviceWorker.getRegistrations())
  .map((r) => ({ escopo: r.scope, script: (r.active || r.waiting || r.installing)?.scriptURL })));

// Relógio adiantável da página: Date.now() + um deslocamento. Não usa o page.clock do Playwright
// porque ele também atrasa a troca do service worker e o teste deixaria de ser fiel.
async function instalarRelogio(page) {
  await page.addInitScript(() => {
    const real = Date.now.bind(Date);
    let deslocamento = 0;
    try { deslocamento = Number(sessionStorage.getItem('__deslocamento') || 0); } catch { /* */ }
    Date.now = () => real() + deslocamento;
    window.__adiantar = (ms) => {
      deslocamento += ms;
      try { sessionStorage.setItem('__deslocamento', String(deslocamento)); } catch { /* */ }
    };
  });
}

// Simula a pessoa sair do site (trocar de app, bloquear o celular) e voltar depois de "minutos" minutos.
async function sairEVoltar(page, minutos) {
  await page.evaluate((ms) => {
    if (!window.__visibilidadeSimulada) {
      window.__visibilidadeSimulada = 'visible';
      Object.defineProperty(document, 'visibilityState', { configurable: true, get: () => window.__visibilidadeSimulada });
    }
    window.__visibilidadeSimulada = 'hidden';
    document.dispatchEvent(new Event('visibilitychange'));
    window.__adiantar(ms);
    window.__visibilidadeSimulada = 'visible';
    document.dispatchEvent(new Event('visibilitychange'));
  }, minutos * 60 * 1000);
}

async function abrirComServiceWorker(page, caminho) {
  await page.goto(base + caminho);
  await page.evaluate(() => navigator.serviceWorker.register('./sw.js', { scope: '/', updateViaCache: 'none' }));
  await page.waitForFunction(async () => !!(await navigator.serviceWorker.getRegistration('/'))?.active);
  await page.reload();
  await page.waitForFunction(() => !!navigator.serviceWorker.controller);
}

test('publicação nova: quem volta para o site depois de 10 minutos recebe a versão nova sozinho', async ({ page }) => {
  await instalarRelogio(page);
  await abrirComServiceWorker(page, '/');
  expect(await versaoDaPagina(page)).toBe('aaaaaaa');
  await expect.poll(() => caches(page)).toEqual(['barberium-aaaaaaa']);

  site.pasta = builds.b; // publicação nova
  await sairEVoltar(page, 3);
  await page.waitForTimeout(1500);
  expect(await versaoDaPagina(page), 'fora por só 3 minutos: não recarrega').toBe('aaaaaaa');

  await sairEVoltar(page, 11);
  await expect.poll(() => versaoDaPagina(page)).toBe('bbbbbbb');
  await expect.poll(() => caches(page), { message: 'o cache da versão antiga é apagado' }).toEqual(['barberium-bbbbbbb']);
  const regs = await registros(page);
  expect(regs).toHaveLength(1);
  expect(regs[0].script).toBe(`${base}/sw.js`);
});

test('não recarrega com alguém digitando; recarrega depois que a pessoa sai do campo', async ({ page }) => {
  await instalarRelogio(page);
  await page.goto(base + '/equipe/');
  expect(await versaoDaPagina(page)).toBe('aaaaaaa');
  site.pasta = builds.b;
  await page.locator('#email').focus();
  await sairEVoltar(page, 15);
  await expect.poll(() => page.evaluate(() => window.__barberiumVersao.publicada())).toBe('bbbbbbb');
  await page.waitForTimeout(1500);
  expect(await versaoDaPagina(page), 'campo de e-mail em uso: não recarrega').toBe('aaaaaaa');

  await page.locator('#email').blur();
  await sairEVoltar(page, 15);
  await expect.poll(() => versaoDaPagina(page)).toBe('bbbbbbb');
});

test('não recarrega com a janela aberta na Área da Equipe', async ({ page }) => {
  await instalarRelogio(page);
  await page.goto(base + '/equipe/');
  site.pasta = builds.b;
  await page.evaluate(() => { const j = document.getElementById('modalBackdrop'); j.classList.remove('hidden'); j.setAttribute('aria-hidden', 'false'); });
  await sairEVoltar(page, 15);
  await page.waitForTimeout(1500);
  expect(await versaoDaPagina(page)).toBe('aaaaaaa');
  await page.evaluate(() => { const j = document.getElementById('modalBackdrop'); j.classList.add('hidden'); j.setAttribute('aria-hidden', 'true'); });
  await sairEVoltar(page, 15);
  await expect.poll(() => versaoDaPagina(page)).toBe('bbbbbbb');
});

test('se a pessoa abrir uma janela enquanto a troca se prepara, espera a próxima vez', async ({ page }) => {
  await instalarRelogio(page);
  await page.goto(base + '/equipe/');
  site.pasta = builds.b;
  // Simula a janela sendo aberta exatamente durante a preparação da troca.
  await page.evaluate(() => {
    const original = navigator.serviceWorker.getRegistration.bind(navigator.serviceWorker);
    window.__restaurar = () => { navigator.serviceWorker.getRegistration = original; };
    navigator.serviceWorker.getRegistration = async () => ({
      installing: null, waiting: null,
      update: async () => { const j = document.getElementById('modalBackdrop'); j.classList.remove('hidden'); j.setAttribute('aria-hidden', 'false'); },
    });
  });
  await sairEVoltar(page, 15);
  await page.waitForTimeout(1500);
  expect(await versaoDaPagina(page)).toBe('aaaaaaa');
  await page.evaluate(() => { window.__restaurar(); const j = document.getElementById('modalBackdrop'); j.classList.add('hidden'); j.setAttribute('aria-hidden', 'true'); });
  await sairEVoltar(page, 15);
  await expect.poll(() => versaoDaPagina(page)).toBe('bbbbbbb');
});

test('página aberta na tela sem ninguém mexer há 30 minutos também atualiza', async ({ page }) => {
  await page.clock.install();
  await page.goto(base + '/equipe/');
  site.pasta = builds.b;
  await page.clock.fastForward(29 * 60 * 1000);
  await page.waitForTimeout(1000);
  expect(await versaoDaPagina(page)).toBe('aaaaaaa');
  await page.clock.fastForward(3 * 60 * 1000);
  await expect.poll(() => versaoDaPagina(page)).toBe('bbbbbbb');
});

test('se a recarga não trouxer a versão nova, não fica recarregando sem parar', async ({ page }) => {
  await instalarRelogio(page);
  let carregamentos = 0;
  page.on('load', () => { carregamentos++; });
  await page.goto(base + '/equipe/');
  site.versaoJson = 'ccccccc'; // diz que há versão nova, mas a página continua sendo a aaaaaaa
  await sairEVoltar(page, 15);
  await expect.poll(() => carregamentos).toBe(2);
  await sairEVoltar(page, 15);
  await sairEVoltar(page, 15);
  await page.waitForTimeout(1500);
  expect(carregamentos, 'recarregou uma vez só').toBe(2);
  expect(await versaoDaPagina(page)).toBe('aaaaaaa');
});

test('celular com o service worker de antes da etapa 4 passa para o novo e apaga o cache velho', async ({ page }) => {
  site.swAntigo = true;
  await page.goto(base + '/');
  await page.evaluate(() => navigator.serviceWorker.register('./sw.js?v=12.4', { updateViaCache: 'none' }));
  await page.waitForFunction(async () => !!(await navigator.serviceWorker.getRegistration('/'))?.active);
  await expect.poll(() => caches(page)).toEqual(['scalabrini-client-v12-48']);

  site.swAntigo = false; // publica a etapa 4
  site.pasta = builds.b;
  await page.goto(base + '/');
  // O Chrome pode manter o antigo ativo enquanto a página ainda carrega; ele troca assim que o
  // antigo fica sem trabalho. Enquanto isso, o antigo já busca páginas e scripts da internet.
  await expect.poll(() => caches(page), { timeout: 60_000 }).toEqual(['barberium-bbbbbbb']);
  await expect.poll(async () => (await registros(page)).map((r) => r.script)).toEqual([`${base}/sw.js`]);
  // A Área da Equipe registra o mesmo service worker: continua um só.
  await page.goto(base + '/equipe/');
  await page.evaluate(() => navigator.serviceWorker.register('../sw.js', { scope: '../', updateViaCache: 'none' }));
  await page.waitForTimeout(1000);
  expect(await registros(page)).toEqual([{ escopo: `${base}/`, script: `${base}/sw.js` }]);
});

test('service worker não guarda a página inicial no lugar de um script que não existe', async ({ page }) => {
  site.pasta = builds.b;
  await abrirComServiceWorker(page, '/');
  const resultado = await page.evaluate(async () => {
    await new Promise((ok) => { const s = document.createElement('script'); s.src = '/nao-existe.js?x=1'; s.onload = s.onerror = ok; document.head.append(s); });
    await new Promise((ok) => setTimeout(ok, 500));
    const cache = await caches.open('barberium-bbbbbbb');
    return {
      inexistente: !!(await cache.match('/nao-existe.js?x=1')),
      app: !!(await cache.match('/app.js?v=bbbbbbb')),
      pagina: !!(await cache.match('/')),
    };
  });
  expect(resultado).toEqual({ inexistente: false, app: true, pagina: true });
});
