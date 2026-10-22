// Painel do dono do SaaS, no site de teste (banco de teste e função de convite de verdade).
// O login de teste dono.barberium@example.com é dono do Barberium só no banco de teste.
// A barbearia "Barbearia Painel Teste" é cadastrada na primeira rodada e reaproveitada nas
// outras: cada rodada gera um link novo para o dono dela, que cria uma senha e entra.
import { test, expect } from '@playwright/test';

const SENHA = process.env.STAGING_SENHA_TESTE || '';
const NOME = 'Barbearia Painel Teste';
const SLUG = 'painel-teste';

async function entrarNoPainel(page, email, senha) {
  await page.goto('/painel/');
  await expect(page.getByText('AMBIENTE DE TESTE')).toBeVisible();
  await page.fill('#painelEmail', email);
  await page.fill('#painelSenha', senha);
  await page.click('#painelEntrar');
}

test('login de barbearia não entra no painel do dono', async ({ page }) => {
  test.skip(SENHA.length < 12 && !process.env.CI, 'sem a senha de teste (segredo STAGING_SENHA_TESTE)');
  await entrarNoPainel(page, 'adm.scalabrini@example.com', SENHA);
  await expect(page.locator('#painelLoginErro')).toHaveText('Este login não é dono do Barberium.');
  await expect(page.locator('#painelApp')).toBeHidden();
});

test('o dono do Barberium cadastra e convida; o convidado cria a senha e entra na barbearia nova', async ({ page, browser }) => {
  test.skip(SENHA.length < 12 && !process.env.CI, 'sem a senha de teste (segredo STAGING_SENHA_TESTE)');
  const erros = [];
  page.on('pageerror', (e) => erros.push(e.message));
  await entrarNoPainel(page, 'dono.barberium@example.com', SENHA);
  await expect(page.locator('.painel-card').first()).toBeVisible();
  await expect(page.locator('.painel-card h3')).toContainText(['Barbearia Aurora']);

  const cartao = page.locator('#painelLista .painel-card', { hasText: NOME });
  if (await cartao.count() === 0) {
    await page.click('#painelNovaBotao');
    await page.fill('#novaNome', NOME);
    await page.fill('#novaSlug', SLUG);
    await page.fill('#novaCidade', 'Campinas');
    await page.fill('#novaUf', 'SP');
    await page.fill('#novaAdmNome', 'Dono Painel Teste');
    await page.fill('#novaAdmEmail', 'adm.painel-teste@example.com');
    await page.click('#novaSalvar');
  } else {
    await cartao.locator('[data-convite]').first().click();
  }
  await expect(page.locator('#painelJanela')).toBeVisible();
  const mensagem = await page.inputValue('#painelTextoConvite');
  const link = /https?:\/\/\S+convite=\S+/.exec(mensagem)?.[0];
  expect(link, 'a mensagem traz o link do convite').toContain(`barbearia=${SLUG}`);
  expect(erros).toEqual([]);

  // O convidado, noutro aparelho.
  const outro = await browser.newContext();
  const p2 = await outro.newPage();
  await p2.goto(link);
  await expect(p2.locator('#conviteForm')).toBeVisible();
  await expect(p2.locator('.login-brand p')).toHaveText(`Acesso reservado à equipe ${NOME}.`);
  const nova = `senha-${Date.now()}`;
  await p2.fill('#conviteSenha', nova);
  await p2.fill('#conviteSenha2', nova);
  await p2.click('#conviteBotao');
  await expect(p2.locator('#dashboardView')).toBeVisible();
  await expect(p2.locator('#roleLabel')).toHaveText('Proprietário');
  await expect(p2.locator('.brand-line small')).toHaveText(NOME.toLocaleUpperCase('pt-BR'));
  expect(p2.url(), 'o código sai do endereço depois de usado').not.toContain('convite=');
  await outro.close();
});
