// Área da Equipe do site de teste: ADM e barbeiro da Scalabrini de teste e ADM da Aurora.
// A senha dos logins de teste vem do segredo STAGING_SENHA_TESTE.
import { test, expect } from '@playwright/test';

const SENHA = process.env.STAGING_SENHA_TESTE || '';

async function entrar(page, email) {
  await page.goto('/equipe/');
  await expect(page.getByText('AMBIENTE DE TESTE')).toBeVisible();
  await page.fill('#email', email);
  await page.fill('#password', SENHA);
  await page.click('#loginButton');
  await expect(page.locator('#dashboardView')).toBeVisible();
  await expect(page.locator('#loginError')).toHaveText('');
}

test('senha errada não entra', async ({ page }) => {
  await page.goto('/equipe/');
  await expect(page.locator('meta[name="barberium-versao"]'), 'página com a versão da publicação (etapa 4)').toHaveAttribute('content', /^[0-9a-f]{7}$/);
  await page.fill('#email', 'adm.scalabrini@example.com');
  await page.fill('#password', 'senha-errada-de-proposito');
  await page.click('#loginButton');
  await expect(page.locator('#loginError')).not.toHaveText('');
  await expect(page.locator('#dashboardView')).toBeHidden();
});

test.describe('com login', () => {
  // No computador, sem a senha, estes testes são pulados. No GitHub a senha é obrigatória.
  test.skip(SENHA.length < 12 && !process.env.CI, 'sem a senha de teste (segredo STAGING_SENHA_TESTE)');

  test('ADM da Scalabrini vê agenda, clientes, financeiro e equipe', async ({ page }) => {
    const erros = [];
    page.on('pageerror', (e) => erros.push(e.message));
    await entrar(page, 'adm.scalabrini@example.com');
    // O painel aparece antes de o papel carregar; esperar o texto do papel evita conferir cedo demais.
    await expect(page.locator('#scopeLabel')).toContainText('toda a equipe');
    await expect(page.locator('#roleLabel')).toHaveText(/Administrador|Proprietário/);
    await expect(page.locator('#agendaPanel')).toBeVisible();
    for (const aba of ['#clientsNav', '#financeNav', '#teamNav']) {
      await expect(page.locator(aba)).toBeVisible();
    }
    await page.locator('#financeNav').click();
    await expect(page.locator('#financePanel')).toBeVisible();
    await page.locator('#teamNav').click();
    await expect(page.locator('#teamPanel')).toContainText('Vinicius Nunes');
    await expect(page.locator('#teamPanel')).not.toContainText('Lucas Mendes');
    expect(erros, 'erros de JavaScript na página').toEqual([]);
  });

  test('barbeiro vê a agenda, mas não clientes nem equipe', async ({ page }) => {
    await entrar(page, 'barbeiro.scalabrini@example.com');
    await expect(page.locator('#scopeLabel')).toContainText('apenas a sua própria agenda');
    await expect(page.locator('#roleLabel')).toHaveText('Barbeiro');
    await expect(page.locator('#welcomeName')).toContainText('Vinicius');
    await expect(page.locator('#agendaPanel')).toBeVisible();
    await expect(page.locator('#clientsNav')).toBeHidden();
    await expect(page.locator('#teamNav')).toBeHidden();
  });

  test('ADM da Aurora só enxerga a Aurora', async ({ page }) => {
    await entrar(page, 'adm.aurora@example.com');
    await expect(page.locator('#scopeLabel')).toContainText('toda a equipe');
    await page.locator('#teamNav').click();
    await expect(page.locator('#teamPanel')).toContainText('Lucas Mendes');
    await expect(page.locator('#teamPanel')).toContainText('Rafael Costa');
    await expect(page.locator('body')).not.toContainText('Vinicius Nunes');
    await expect(page.locator('body')).not.toContainText('Jean Dalarmi');
  });
});
