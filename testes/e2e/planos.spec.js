// Etapa 7e, no site de teste: Planos e Contratos ativos do Financeiro e os valores da comissão de
// planos (os remendos v12.9, v12.17, v12.20 e v12.22 não carregam mais). Só olha: não salva nada.
import { test, expect } from '@playwright/test';

const SENHA = process.env.STAGING_SENHA_TESTE || '';

test('Planos: abas Planos e Contratos ativos; "25.50" na comissão vira "25,50"', async ({ page }) => {
  test.skip(SENHA.length < 12 && !process.env.CI, 'sem a senha de teste (segredo STAGING_SENHA_TESTE)');
  const erros = [];
  const antigos = [];
  page.on('pageerror', (e) => erros.push(e.message));
  page.on('request', (r) => { if (/barberium-v12\.(9|17)\.js/.test(r.url())) antigos.push(r.url()); });
  await page.goto('/equipe/');
  await expect(page.getByText('AMBIENTE DE TESTE')).toBeVisible();
  await page.fill('#email', 'adm.scalabrini@example.com');
  await page.fill('#password', SENHA);
  await page.click('#loginButton');
  await expect(page.locator('#roleLabel')).toHaveText(/Administrador|Proprietário/);

  await page.click('[data-team-panel="finance"]');
  await page.click('[data-finance-tab="plans"]');
  const abas = page.locator('#v129PlanTabs');
  await expect(abas.locator('button.active')).toHaveText('Planos');
  await expect(page.locator('#membershipPlanList .plan-card, #membershipPlanList .empty').first()).toBeVisible();

  await abas.getByRole('button', { name: 'Contratos ativos' }).click();
  await expect(page.locator('#v129PlanCatalogTab')).toBeHidden();
  await expect(page.locator('#v129ContractsList [data-v129-contract], #v129ContractsList .empty').first()).toBeVisible();
  await page.fill('#v129ContractSearch', 'zzz nenhum contrato zzz');
  await expect(page.locator('#v129ContractsList .empty')).toHaveText('Nenhum contrato encontrado.');

  await abas.getByRole('button', { name: 'Planos' }).click();
  await page.click('#newPlanButton');
  await page.selectOption('#planCommissionType', 'hour');
  await page.fill('#planHourlyRate', '25.50');
  await page.click('#planName');
  await expect(page.locator('#planHourlyRate')).toHaveValue('25,50');
  await page.click('#modalClose');

  expect(antigos).toEqual([]);
  expect(erros).toEqual([]);
});
