// Etapa 7d, no site de teste: as abas "Agenda" e "Cancelados" e o cancelamento num módulo só
// (os remendos v12.8 e v12.45 não carregam mais). Só olha: não cancela nada.
import { test, expect } from '@playwright/test';

const SENHA = process.env.STAGING_SENHA_TESTE || '';

test('Agenda e Cancelados: cada aba mostra só o que é dela, sem os remendos antigos', async ({ page }) => {
  test.skip(SENHA.length < 12 && !process.env.CI, 'sem a senha de teste (segredo STAGING_SENHA_TESTE)');
  const erros = [];
  const antigos = [];
  page.on('pageerror', (e) => erros.push(e.message));
  page.on('request', (r) => { if (/agenda-cancelados-v12\.8|cancel-permission-v12\.45/.test(r.url())) antigos.push(r.url()); });
  await page.goto('/equipe/');
  await expect(page.getByText('AMBIENTE DE TESTE')).toBeVisible();
  await page.fill('#email', 'adm.scalabrini@example.com');
  await page.fill('#password', SENHA);
  await page.click('#loginButton');
  await expect(page.locator('#roleLabel')).toHaveText(/Administrador|Proprietário/);

  const abas = page.locator('#agendaStatusTabs');
  const titulo = page.locator('#agendaPanel .agenda-section .section-head h2');
  await expect(abas.locator('button.active')).toHaveText('Agenda');
  await expect(titulo).toHaveText('Agenda do dia');
  await expect(page.locator('#agendaList .agenda-item, #agendaList .empty').first()).toBeVisible();
  await expect(page.locator('#agendaList .status.cancelled')).toHaveCount(0);

  await abas.getByRole('button', { name: 'Cancelados' }).click();
  await expect(abas.locator('button.active')).toHaveText('Cancelados');
  await expect(titulo).toHaveText('Cancelamentos do dia');
  const cancelados = page.locator('#agendaList .agenda-item');
  if (await cancelados.count()) {
    await expect(page.locator('#agendaList .agenda-item:not(:has(.status.cancelled))')).toHaveCount(0);
  } else {
    await expect(page.locator('#agendaList .empty')).toHaveText('Nenhum cancelamento nesta data.');
  }

  await abas.getByRole('button', { name: 'Agenda' }).click();
  await expect(titulo).toHaveText('Agenda do dia');
  await expect(page.locator('#agendaList .status.cancelled')).toHaveCount(0);

  // Se houver um horário confirmado no dia, o "Cancelado" do ADM abre a classificação. Fecha sem confirmar.
  const confirmado = page.locator('#agendaList .agenda-item:has(.status.confirmed)').first();
  if (await confirmado.count()) {
    await confirmado.click();
    await page.click('#statusActions [data-new-status="cancelled"]');
    await expect(page.locator('#v128CancelKind')).toHaveValue('regular');
    await expect(page.locator('#v128CancelForm')).toContainText('Engano / erro de agendamento');
    await page.click('#modalClose');
  }

  expect(antigos).toEqual([]);
  expect(erros).toEqual([]);
});
