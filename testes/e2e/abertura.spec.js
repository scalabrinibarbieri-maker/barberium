// Etapa 7h (parte 1), no site de teste: abertura do site do cliente. O remendo
// barberium-client-v12.24.js não carrega mais; o catálogo é buscado na abertura e quem toca em
// "Agendar" antes dele chegar vê "Carregando serviços…" e depois a lista (antes: lista vazia).
// Só olha: não grava nada.
import { test, expect } from '@playwright/test';

const siteAberto = (page) => page.waitForFunction(() => !document.documentElement.classList.contains('barberium-splash-pending'), null, { timeout: 15000 });

test('abertura: marca da barbearia, capa animada e sem o remendo antigo', async ({ page }) => {
  const erros = [];
  const antigos = [];
  page.on('pageerror', (e) => erros.push(e.message));
  page.on('request', (r) => { if (/barberium-client-v12\.24\.js/.test(r.url())) antigos.push(r.url()); });
  await page.goto('/');
  await siteAberto(page);
  await expect(page.locator('#barberiumMaintenance'), 'o site de teste deveria abrir sem manutenção').toHaveCount(0);
  await expect(page.locator('.hero-content')).toHaveClass(/v1244-done/, { timeout: 8000 });
  await expect(page.locator('.v1244-logo-stage .v1244-logo-glint')).toHaveAttribute('src', /\S/);
  await expect(page.locator('.brand-button strong')).not.toBeEmpty();
  expect(await page.evaluate(() => document.documentElement.classList.contains('barberium-hero-pending'))).toBe(false);
  expect(antigos).toEqual([]);
  expect(erros).toEqual([]);
});

test('Agendar logo ao abrir, com o catálogo demorando, mostra os serviços', async ({ page }) => {
  const erros = [];
  page.on('pageerror', (e) => erros.push(e.message));
  // O catálogo demora mais que a tela de abertura (que sai sozinha em 2,2 s).
  await page.route('**/rpc/barberium_get_catalog', async (rota) => {
    await new Promise((ok) => setTimeout(ok, 3500));
    await rota.continue();
  });
  await page.goto('/');
  await siteAberto(page);
  await page.evaluate(() => document.querySelector('[data-nav="booking"]').click());
  await expect(page.locator('#bookingStage')).toContainText('Carregando serviços');
  await expect(page.locator('[data-service]').first()).toBeVisible({ timeout: 15000 });
  expect(erros).toEqual([]);
});
