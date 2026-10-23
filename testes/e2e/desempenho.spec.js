// Etapa 7f, no site de teste: Desempenho com produtos e Horários livres da Agenda (os remendos
// v12.10 e v12.33 não carregam mais). Só olha: não grava nada.
import { test, expect } from '@playwright/test';

const SENHA = process.env.STAGING_SENHA_TESTE || '';

test('Desempenho com 6 cartões e produtos; Horários livres na Agenda', async ({ page }) => {
  test.skip(SENHA.length < 12 && !process.env.CI, 'sem a senha de teste (segredo STAGING_SENHA_TESTE)');
  const erros = [];
  const antigos = [];
  const resumos = [];
  page.on('pageerror', (e) => erros.push(e.message));
  page.on('request', (r) => {
    if (/barberium-v12\.10\.js|staff-tools-v12\.33\.js/.test(r.url())) antigos.push(r.url());
    if (/rpc\/barberium_staff_performance$/.test(r.url())) resumos.push(r.url());
  });
  await page.goto('/equipe/');
  await expect(page.getByText('AMBIENTE DE TESTE')).toBeVisible();
  await page.fill('#email', 'adm.scalabrini@example.com');
  await page.fill('#password', SENHA);
  await page.click('#loginButton');
  await expect(page.locator('#roleLabel')).toHaveText(/Administrador|Proprietário/);

  await page.click('#performanceNav');
  await expect(page.locator('#performanceCards .performance-card')).toHaveCount(6);
  await expect(page.locator('#performanceCards')).toContainText('Produtos vendidos');
  await expect(page.locator('.services-performance .section-head small')).toHaveText('SERVIÇOS + PRODUTOS');
  await expect(page.locator('#servicesPerformance .service-stat, #servicesPerformance .empty').first()).toBeVisible();
  expect(resumos.length).toBe(1);

  await page.click('[data-team-panel="agenda"]');
  await page.click('#v1233FreeTimesButton');
  await expect(page.locator('#modalTitle')).toHaveText('Horários livres');
  await expect(page.locator('#modalBody .v1233-free-list, #modalBody .empty').first()).toBeVisible();
  await page.click('#modalClose');

  expect(antigos).toEqual([]);
  expect(erros).toEqual([]);
});
