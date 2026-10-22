// Etapa 7a, no site de teste: o cartão "Área do cliente" de Ajustes → Barbearia e a manutenção
// valendo também no banco.
import { test, expect } from '@playwright/test';

const SENHA = process.env.STAGING_SENHA_TESTE || '';

test('ADM abre Ajustes → Barbearia, vê o cartão "Área do cliente" e salva', async ({ page }) => {
  test.skip(SENHA.length < 12 && !process.env.CI, 'sem a senha de teste (segredo STAGING_SENHA_TESTE)');
  const erros = [];
  page.on('pageerror', (e) => erros.push(e.message));
  await page.goto('/equipe/?barbearia=barbearia-aurora');
  await expect(page.getByText('AMBIENTE DE TESTE')).toBeVisible();
  await page.fill('#email', 'adm.aurora@example.com');
  await page.fill('#password', SENHA);
  await page.click('#loginButton');
  await expect(page.locator('#dashboardView')).toBeVisible();
  await expect(page.locator('#teamNav small')).toHaveText('Ajustes');
  await page.locator('#teamNav').click();
  await page.locator('#settingsNav').click();
  await page.locator('[data-settings-tab="business"]').click();
  const cartao = page.locator('#v1224ClientAppearance');
  await expect(cartao).toBeVisible();
  await expect(cartao).toContainText('Área do cliente');
  await expect(cartao).toContainText('Modo manutenção da Área do Cliente');
  await expect(cartao).toContainText('Apresentação da página inicial');
  await expect(page.locator('#v1224HeroTitle')).not.toHaveValue('');
  // Salva sem mudar nada: grava os mesmos valores.
  await cartao.locator('[type=submit]').click();
  await expect(page.locator('#toast')).toContainText('Personalização salva.');
  expect(erros).toEqual([]);
});

test('o banco não aceita agendamento pelo site numa barbearia em manutenção', async ({ page }) => {
  await page.goto('/?barbearia=barbearia-aurora');
  await expect(page.getByText('AMBIENTE DE TESTE')).toBeVisible();
  // A "Barbearia Painel Teste" (do teste do painel) nasce em manutenção e ninguém a abre.
  const r = await page.evaluate(async () => {
    const { SUPABASE_URL, SUPABASE_KEY } = await import('/shared/config.js?v=1');
    const chamar = async (nome, args) => {
      const resp = await fetch(`${SUPABASE_URL}/rest/v1/rpc/${nome}`, {
        method: 'POST', headers: { apikey: SUPABASE_KEY, 'Content-Type': 'application/json' }, body: JSON.stringify(args),
      });
      return { status: resp.status, dados: await resp.json().catch(() => null) };
    };
    const t = await chamar('barberium_resolve_tenant', { p_host: location.hostname, p_barbershop_slug: 'painel-teste', p_unit_slug: null });
    const unidade = t.dados?.unit?.slug || t.dados?.units?.[0]?.slug;
    if (!unidade) return { semBarbearia: true };
    const zero = '00000000-0000-0000-0000-000000000000';
    return chamar('barberium_create_appointment', {
      p_barbershop_slug: 'painel-teste', p_unit_slug: unidade, p_professional_id: zero, p_service_id: zero, p_addon_service_ids: [],
      p_date: '2099-01-05', p_time: '10:00', p_full_name: 'Teste Manutencao', p_phone: '(11) 90000-0000', p_birthday: null, p_existing_token: null,
    });
  });
  test.skip(r.semBarbearia === true, 'a "Barbearia Painel Teste" ainda não existe neste banco (o teste do painel cria)');
  expect(r.status).toBe(400);
  expect(JSON.stringify(r.dados)).toContain('UNIT_IN_MAINTENANCE');
});
