// Etapa 7g (parte 2), no site de teste: Saldos dentro do Financeiro (o remendo v12.39 não
// carrega mais). Só olha: não grava nada.
import { test, expect } from '@playwright/test';

const SENHA = process.env.STAGING_SENHA_TESTE || '';

test('Saldos abre no Financeiro, mostra a Casa e fecha ao trocar de aba', async ({ page }) => {
  test.skip(SENHA.length < 12 && !process.env.CI, 'sem a senha de teste (segredo STAGING_SENHA_TESTE)');
  const erros = [];
  const antigos = [];
  const saldos = [];
  page.on('pageerror', (e) => erros.push(e.message));
  page.on('request', (r) => {
    if (/balances-v12\.39\.js/.test(r.url())) antigos.push(r.url());
    if (/rpc\/barberium_staff_balance_quick$/.test(r.url())) saldos.push(r.url());
  });
  await page.goto('/equipe/');
  await expect(page.getByText('AMBIENTE DE TESTE')).toBeVisible();
  await page.fill('#email', 'adm.scalabrini@example.com');
  await page.fill('#password', SENHA);
  await page.click('#loginButton');
  await expect(page.locator('#roleLabel')).toHaveText(/Administrador|Proprietário/);

  await page.click('[data-team-panel="finance"]');
  await expect(page.locator('#financeTabs > *').first()).toHaveText('Saldos');
  await page.click('#v1239BalancesTab');
  await expect(page.locator('#financeBalancesTab')).toBeVisible();
  await expect(page.locator('#financeAdminControls')).toBeHidden();
  await expect(page.locator('#v1239ScopeLabel')).toHaveText('Casa + comissões da equipe');
  await expect(page.locator('#v1239Content .v1239-category')).toHaveCount(3);

  await page.click('[data-v1239-preset="month"]');
  await expect(page.locator('[data-v1239-preset="month"]')).toHaveClass(/active/);
  await expect(page.locator('#v1239Content [data-v1239-house]')).toBeVisible();
  await page.click('#v1239Content [data-v1239-house]');
  await expect(page.locator('#modalBody .v1239-house-lines')).toBeVisible();
  await page.click('#modalClose');
  // Saldos foi tocada enquanto o Financeiro ainda carregava: continua aberta depois do carregamento.
  await expect(page.locator('#v1239BalancesTab')).toHaveClass(/active/);
  await expect(page.locator('#financeOverviewTab')).toBeHidden();

  await page.click('[data-finance-tab="overview"]');
  await expect(page.locator('#financeBalancesTab')).toBeHidden();
  await expect(page.locator('#financeAdminControls')).toBeVisible();
  await expect(page.locator('#v1239BalancesTab')).not.toHaveClass(/active/);

  expect(saldos.length).toBe(2);
  expect(antigos).toEqual([]);
  expect(erros).toEqual([]);
});
