// Etapa 7c, no site de teste: o formulário de "Novo horário" com vários serviços na comanda e
// o cliente passageiro. Só preenche e fecha: não grava nada.
import { test, expect } from '@playwright/test';

const SENHA = process.env.STAGING_SENHA_TESTE || '';
const reais = (t) => Number(String(t).replace(/[^\d,]/g, '').replace(',', '.'));

test('Novo horário: serviço extra soma no preço e entra na busca de horários; cliente passageiro', async ({ page }) => {
  test.skip(SENHA.length < 12 && !process.env.CI, 'sem a senha de teste (segredo STAGING_SENHA_TESTE)');
  const erros = [];
  page.on('pageerror', (e) => erros.push(e.message));
  await page.goto('/equipe/');
  await expect(page.getByText('AMBIENTE DE TESTE')).toBeVisible();
  await page.fill('#email', 'adm.scalabrini@example.com');
  await page.fill('#password', SENHA);
  await page.click('#loginButton');
  await expect(page.locator('#roleLabel')).toHaveText(/Administrador|Proprietário/);

  await page.click('#newAppointmentButton');
  await expect(page.locator('#v1212ExtraServiceBox')).toContainText('Serviços da comanda');
  await page.selectOption('#bookingService', { label: 'Corte' });
  await expect(page.locator('#v1212SelectedServices')).toContainText('Nenhum outro serviço adicionado.');
  const antes = reais(await page.textContent('#listedPrice'));

  await page.click('#v1212AddService');
  const opcao = page.locator('#v1212ServiceSelect option', { hasText: 'Barba Tradizionale' });
  const extra = await opcao.getAttribute('value');
  const precoExtra = reais((await opcao.textContent()).split('•')[1]);
  const busca = page.waitForRequest((r) => /rpc\/barberium_staff_available_slots_v12_12/.test(r.url()) && (r.postData() || '').includes(extra));
  await page.selectOption('#v1212ServiceSelect', extra);
  await page.click('#v1212ConfirmService');
  await expect(page.locator('#v1212SelectedServices')).toContainText('Barba Tradizionale');
  await expect(page.locator('#listedPrice')).toHaveText(new RegExp((antes + precoExtra).toFixed(2).replace('.', ',')));
  await busca;

  await page.click('#v1221PassengerButton');
  await expect(page.locator('#v1221PassengerButton')).toHaveText('Usar cliente identificado');
  await expect(page.locator('#selectedCustomerWrap')).toContainText('Cliente passageiro');
  await expect(page.locator('#customerSearch')).toBeHidden();
  await page.click('#v1221PassengerButton');
  await expect(page.locator('#customerSearch')).toBeVisible();

  await page.click('#modalClose');
  expect(erros).toEqual([]);
});
