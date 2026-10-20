// Cliente pelo site de teste: agenda um horário, vê em "Meus horários" e cancela.
// O horário é cancelado no fim para o teste não ir enchendo a agenda do teste.
import { test, expect } from '@playwright/test';

const clicar = (page, seletor) => page.evaluate((s) => document.querySelector(s)?.click(), seletor);

test('cliente agenda, vê em "Meus horários" e cancela', async ({ page }) => {
  const erros = [];
  page.on('pageerror', (e) => erros.push(e.message));

  // Espera o catálogo carregar: tocar em "Agendar" antes disso deixa a lista de serviços vazia
  // (defeito conhecido do site do cliente, anotado para a etapa 7h).
  await page.goto('/', { waitUntil: 'networkidle' });
  await expect(page.getByText('AMBIENTE DE TESTE')).toBeVisible();
  await expect(page.locator('meta[name="barberium-versao"]'), 'página com a versão da publicação (etapa 4)').toHaveAttribute('content', /^[0-9a-f]{7}$/);
  await page.waitForFunction(() => document.querySelector('[data-nav="booking"]'));
  expect(await page.evaluate(() => document.body.classList.contains('barberium-maintenance-active')),
    'o site de teste deveria abrir sem manutenção').toBe(false);

  // Serviço e profissional: os primeiros da lista.
  await clicar(page, '[data-nav="booking"]');
  await page.locator('[data-service]').first().click();
  await clicar(page, '#serviceNext');
  await page.locator('[data-pro]').first().click();
  await clicar(page, '#proNext');

  // Primeiro dia com horário livre. Hoje à noite ou domingo não há horário: o site mostra
  // "Não há horários disponíveis" e o teste volta (botão de voltar do site) e tenta o dia seguinte.
  const dias = page.locator('[data-date]');
  await expect(dias.first()).toBeVisible();
  let achou = false;
  for (let i = 0; i < 10 && !achou; i++) {
    await dias.nth(i).click();
    await clicar(page, '#dateNext');
    await page.waitForFunction(() => {
      const etapa = document.querySelector('#bookingStage');
      return etapa && !etapa.textContent.includes('Carregando') && etapa.querySelector('[data-time], .no-times');
    }, null, { timeout: 20000 });
    achou = (await page.locator('[data-time]').count()) > 0;
    if (!achou) await clicar(page, '#bookingBack');
  }
  expect(achou, 'nenhum dia com horário livre nos próximos 10').toBe(true);
  await page.locator('[data-time]').first().click();
  await page.waitForSelector('#timeNext');
  await clicar(page, '#timeNext');

  // Dados do cliente (nome e telefone inventados).
  const sufixo = String(Date.now()).slice(-7);
  await page.fill('#fullName', `Teste Automatico ${sufixo}`);
  await page.fill('#phone', `1196${sufixo}`);
  await page.locator('#customerForm button').last().click();
  await page.waitForSelector('#confirmBooking');
  await clicar(page, '#confirmBooking');
  await expect(page.locator('.confirmation')).toBeVisible();

  // Meus horários e cancelamento.
  await clicar(page, '[data-nav="appointments"]');
  const cancelar = page.locator('[data-cancel]').first();
  await expect(cancelar).toBeVisible();
  await cancelar.click();
  await page.locator('#confirmCancel').click();
  await expect(page.locator('#toast')).toContainText('Agendamento cancelado');

  expect(erros, 'erros de JavaScript na página').toEqual([]);
});
