// Etapa 6 · barbearia pelo endereço do site. Monta o site de teste e serve no próprio computador,
// ligado ao banco de teste de verdade. No banco de teste, "127.0.0.1" é um endereço cadastrado
// (abre a Scalabrini de teste, fixa em Bragança, e aceita ?barbearia=) e "localhost" não é.
// Só lê: nenhum horário é marcado aqui.
import { test, expect } from '@playwright/test';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, readFileSync, existsSync, statSync } from 'node:fs';
import { createServer } from 'node:http';
import { tmpdir } from 'node:os';
import { join, extname, normalize } from 'node:path';
import { fileURLToPath } from 'node:url';

const RAIZ_REPO = fileURLToPath(new URL('../..', import.meta.url));
const TIPOS = { '.html': 'text/html; charset=utf-8', '.js': 'application/javascript', '.css': 'text/css',
  '.json': 'application/json', '.webp': 'image/webp', '.svg': 'image/svg+xml', '.webmanifest': 'application/manifest+json' };

test.describe.configure({ mode: 'serial' });

let servidor, porta, pasta;
test.beforeAll(async () => {
  pasta = join(mkdtempSync(join(tmpdir(), 'barberium-tenant-')), 'site');
  execFileSync('bash', [join(RAIZ_REPO, 'deploy/montar_site.sh'), pasta, 'teste'], { env: { ...process.env, VERSAO_SITE: 'eeeeeee' }, stdio: 'pipe' });
  servidor = createServer((req, res) => {
    const caminho = decodeURIComponent(new URL(req.url, 'http://x').pathname);
    let arquivo = normalize(join(pasta, caminho.endsWith('/') ? caminho + 'index.html' : caminho));
    if (!arquivo.startsWith(pasta) || !existsSync(arquivo) || statSync(arquivo).isDirectory()) arquivo = join(pasta, 'index.html');
    res.writeHead(200, { 'Content-Type': TIPOS[extname(arquivo)] || 'application/octet-stream', 'Cache-Control': 'no-cache' });
    res.end(readFileSync(arquivo));
  });
  await new Promise((ok) => servidor.listen(0, '127.0.0.1', ok));
  porta = servidor.address().port;
});
test.afterAll(async () => { await new Promise((ok) => servidor.close(ok)); });

const siteAberto = (page) => page.waitForFunction(() => !document.documentElement.classList.contains('barberium-splash-pending')
  && document.querySelector('.brand-button strong')?.textContent && !document.getElementById('barberiumTenantTela'));

function gravarCatalogos(page) {
  const pedidos = [];
  page.on('request', (r) => { if (r.url().endsWith('/rpc/barberium_get_catalog')) pedidos.push(JSON.parse(r.postData() || '{}')); });
  return pedidos;
}

test('endereço não cadastrado: aviso na tela e o site não abre', async ({ page }) => {
  const erros = [];
  page.on('pageerror', (e) => erros.push(e.message));
  const catalogos = gravarCatalogos(page);
  await page.goto(`http://localhost:${porta}/`);
  await expect(page.locator('#barberiumTenantTela')).toContainText('Endereço não encontrado');
  await page.waitForTimeout(1000);
  expect(catalogos, 'nenhum catálogo pedido').toEqual([]);
  expect(erros).toEqual([]);
});

test('endereço com unidade fixa: abre direto, sem escolha e sem "Trocar unidade"', async ({ page }) => {
  const catalogos = gravarCatalogos(page);
  await page.goto(`http://127.0.0.1:${porta}/`);
  await siteAberto(page);
  await expect(page.locator('.brand-button small')).toContainText(/Bragança/i);
  await expect(page.locator('.barberium-trocar-unidade')).toHaveCount(0);
  expect(catalogos.length).toBeGreaterThan(0);
  for (const c of catalogos) expect(c).toMatchObject({ p_barbershop_slug: 'scalabrini-barbieri', p_unit_slug: 'braganca-paulista' });
});

test('barbearia com duas unidades e sem unidade fixa: o cliente escolhe, e pode trocar', async ({ page }) => {
  const erros = [];
  page.on('pageerror', (e) => erros.push(e.message));
  const catalogos = gravarCatalogos(page);
  await page.goto(`http://127.0.0.1:${porta}/?barbearia=barbearia-aurora`);
  const opcoes = page.locator('#barberiumTenantTela .bt-unidade strong');
  await expect(opcoes).toHaveText(['Unidade Centro', 'Unidade Norte']);
  expect(catalogos, 'nada do site carrega antes da escolha').toEqual([]);
  await page.locator('.bt-unidade', { hasText: 'Unidade Norte' }).click();
  await siteAberto(page);
  await expect(page.locator('.brand-button strong')).toHaveText('Barbearia Aurora');
  await expect(page.locator('.brand-button small')).toContainText('Norte');
  for (const c of catalogos) expect(c).toMatchObject({ p_barbershop_slug: 'barbearia-aurora', p_unit_slug: 'norte' });
  expect(await page.locator('body').innerText()).not.toContain('Scalabrini');

  // Volta para o site: lembra a barbearia (nesta aba) e a unidade (no aparelho).
  await page.goto(`http://127.0.0.1:${porta}/`);
  await siteAberto(page);
  await expect(page.locator('.brand-button small')).toContainText('Norte');

  await page.locator('.barberium-trocar-unidade').click();
  await page.locator('.bt-unidade', { hasText: 'Unidade Centro' }).click();
  await siteAberto(page);
  await expect(page.locator('.brand-button small')).toContainText('Centro');
  expect(erros).toEqual([]);
});

test('sem conexão ao abrir: aviso com "Tentar de novo", que abre o site quando a conexão volta', async ({ page }) => {
  await page.route('**/rpc/barberium_resolve_tenant', (r) => r.abort('internetdisconnected'));
  await page.goto(`http://127.0.0.1:${porta}/`);
  await expect(page.locator('#barberiumTenantTela')).toContainText('Sem conexão');
  await page.unroute('**/rpc/barberium_resolve_tenant');
  await page.locator('[data-tentar]').click();
  await siteAberto(page);
});
