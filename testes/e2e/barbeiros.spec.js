// Etapa 6C, no site de teste: o ADM da Aurora convida um barbeiro, que cria a senha e entra;
// um profissional novo na agenda vira alerta no painel do dono do Barberium, que avisa sem valor
// e decide a cobrança.
// Rafael Costa: na primeira rodada recebe "Convidar"; nas outras, "Senha nova" (o login já existe).
// "Profissional Alerta Teste": criado na primeira rodada; nas outras, é reativado (outro alerta).
// No fim ele volta a ficar inativo, para não aparecer na agenda da Aurora de teste.
import { test, expect } from '@playwright/test';

const SENHA = process.env.STAGING_SENHA_TESTE || '';
const AURORA = '/equipe/?barbearia=barbearia-aurora';
const PROF = 'Profissional Alerta Teste';

async function entrarNaEquipe(page, email, senha) {
  await page.goto(AURORA);
  await expect(page.getByText('AMBIENTE DE TESTE')).toBeVisible();
  await page.fill('#email', email);
  await page.fill('#password', senha);
  await page.click('#loginButton');
  await expect(page.locator('#dashboardView')).toBeVisible();
  await expect(page.locator('#roleLabel')).not.toHaveText('');
}

// Cria (ou desativa e reativa) o profissional do alerta, pela mesma função que a tela Ajustes usa.
function profissionalDoAlerta(page, ativo) {
  return page.evaluate(async ({ nome, ativo }) => {
    const { criarCliente } = await import('/shared/api.js?v=1');
    const { rpc } = criarCliente();
    const boot = await rpc('barberium_staff_settings_bootstrap');
    const p = boot.professionals.find((x) => x.name === nome);
    const unidade = p?.unit_id || boot.units.find((u) => u.is_active)?.id;
    await rpc('barberium_staff_save_professional', {
      p_professional_id: p?.id || null, p_unit_id: unidade, p_name: nome,
      p_image_path: p?.image_path || null, p_is_active: ativo, p_sort_order: p?.sort_order ?? 99,
    });
    return !!p?.is_active;
  }, { nome: PROF, ativo });
}

test.describe('convite de barbeiros e alertas', () => {
  test.skip(SENHA.length < 12 && !process.env.CI, 'sem a senha de teste (segredo STAGING_SENHA_TESTE)');

  test('o ADM convida um barbeiro; ele cria a senha e entra como barbeiro', async ({ page, browser }) => {
    const erros = [];
    page.on('pageerror', (e) => erros.push(e.message));
    await entrarNaEquipe(page, 'adm.aurora@example.com', SENHA);
    await page.locator('#teamNav').click();
    const rafael = page.locator('#teamList .team-card', { has: page.locator('h3', { hasText: 'Rafael Costa' }) });
    const botao = rafael.locator('[data-convidar]');
    await expect(botao).toHaveText(/^(Convidar|Senha nova)$/);
    const primeiraVez = (await botao.innerText()) === 'Convidar';
    await botao.click();
    await expect(page.locator('#conviteBarbeiroForm')).toBeVisible();
    if (primeiraVez) {
      await page.fill('#conviteBarbeiroEmail', 'barbeiro.aurora@example.com');
      await page.fill('#conviteBarbeiroWhats', '(19) 97777-2222');
    } else {
      await expect(page.locator('#conviteBarbeiroEmail')).toHaveValue('barbeiro.aurora@example.com');
    }
    await page.click('#conviteBarbeiroGerar');
    await expect(page.locator('#conviteBarbeiroTexto')).toBeVisible();
    const mensagem = await page.inputValue('#conviteBarbeiroTexto');
    const link = /https?:\/\/\S+convite=\S+/.exec(mensagem)?.[0];
    expect(link, 'a mensagem traz o link do convite').toContain('barbearia=barbearia-aurora');
    expect(mensagem).toContain('Barbearia Aurora');
    expect(erros).toEqual([]);

    // O barbeiro, noutro aparelho.
    const outro = await browser.newContext();
    const p2 = await outro.newPage();
    await p2.goto(link);
    await expect(p2.locator('#conviteForm')).toBeVisible();
    const nova = `senha-${Date.now()}`;
    await p2.fill('#conviteSenha', nova);
    await p2.fill('#conviteSenha2', nova);
    await p2.click('#conviteBotao');
    await expect(p2.locator('#dashboardView')).toBeVisible();
    await expect(p2.locator('#roleLabel')).toHaveText('Barbeiro');
    await expect(p2.locator('.brand-line small')).toHaveText('BARBEARIA AURORA');
    await expect(p2.locator('#teamNav')).toBeHidden();
    expect(p2.url(), 'o código sai do endereço depois de usado').not.toContain('convite=');
    await outro.close();
  });

  test('profissional novo vira alerta no painel: aviso sem valor, cobrar e não cobrar', async ({ page, browser }) => {
    const erros = [];
    page.on('pageerror', (e) => erros.push(e.message));
    await entrarNaEquipe(page, 'adm.aurora@example.com', SENHA);
    if (await profissionalDoAlerta(page, true)) {
      // Já estava ativo (rodada anterior interrompida): desativa e reativa para gerar o alerta.
      await profissionalDoAlerta(page, false);
      await profissionalDoAlerta(page, true);
    }

    const ctx = await browser.newContext();
    await ctx.route('https://wa.me/**', (r) => r.fulfill({ status: 200, contentType: 'text/html', body: 'ok' }));
    const painel = await ctx.newPage();
    painel.on('pageerror', (e) => erros.push(e.message));
    await painel.goto('/painel/');
    await painel.fill('#painelEmail', 'dono.barberium@example.com');
    await painel.fill('#painelSenha', SENHA);
    await painel.click('#painelEntrar');
    const pendente = painel.locator('#painelAlertas [data-alerta]', { hasText: PROF }).filter({ hasText: 'Aguardando sua decisão' });
    await expect(pendente).toHaveCount(1);
    await expect(pendente).toContainText('Barbearia Aurora');
    const id = await pendente.getAttribute('data-alerta');
    const alerta = painel.locator(`#painelAlertas [data-alerta="${id}"]`);
    await expect(painel.locator('#painelAlertasConta')).toBeVisible();

    const href = await alerta.locator('[data-avisar]').getAttribute('href');
    const texto = decodeURIComponent(href.split('?text=')[1] || '');
    expect(texto).toContain(PROF);
    expect(texto).toContain('Nas próximas horas, enviaremos o custo deste novo profissional.');
    expect(texto, 'o aviso não mostra valor').not.toMatch(/R\$|\d+,\d{2}/);
    const [whats] = await Promise.all([ctx.waitForEvent('page'), alerta.locator('[data-avisar]').click()]);
    await whats.close();
    await expect(alerta).toContainText('Dono avisado em');

    await alerta.locator('[data-cobrar]').click();
    await expect(painel.locator('#painelAviso')).toContainText('Informe o valor');
    await alerta.locator('[data-valor]').fill('25,00');
    await alerta.locator('[data-cobrar]').click();
    await expect(alerta).toContainText(/Cobrar R\$\s25,00 na próxima fatura/);
    const aurora = painel.locator('#painelLista .painel-card', { hasText: 'Barbearia Aurora' });
    await expect(aurora).toContainText(/Próxima fatura: \+ \d+ profissiona/);

    await alerta.locator('[data-nao-cobrar]').click();
    await expect(alerta.locator('.painel-alerta-situacao')).toHaveText('Não cobrar');
    await ctx.close();

    await profissionalDoAlerta(page, false);
    expect(erros).toEqual([]);
  });
});
