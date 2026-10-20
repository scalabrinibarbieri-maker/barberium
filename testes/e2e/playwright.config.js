// Testes de ponta a ponta (etapa 3). Rodam SÓ contra o site de teste, nunca contra a produção.
import { defineConfig } from '@playwright/test';

const SITE = process.env.SITE_TESTE || 'https://staging.barberium.pages.dev';
if (!/^https:\/\/([a-z0-9-]+\.)?staging\.barberium\.pages\.dev\/?$|^http:\/\/127\.0\.0\.1:\d+\/?$/.test(SITE)) {
  throw new Error(`Estes testes só rodam no site de teste. Endereço recusado: ${SITE}`);
}

export default defineConfig({
  testDir: '.',
  timeout: 90_000,
  expect: { timeout: 15_000 },
  retries: process.env.CI ? 1 : 0,
  workers: 1,
  reporter: process.env.CI
    ? [['list'], ['github'], ['html', { open: 'never', outputFolder: 'relatorio' }]]
    : [['list'], ['html', { open: 'never', outputFolder: 'relatorio' }]],
  use: {
    baseURL: SITE,
    locale: 'pt-BR',
    timezoneId: 'America/Sao_Paulo',
    viewport: { width: 390, height: 844 },
    serviceWorkers: 'block',
    trace: 'retain-on-failure',
    screenshot: 'only-on-failure',
  },
});
