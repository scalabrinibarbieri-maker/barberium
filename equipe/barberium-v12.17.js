// Barberium v12.17 — atualização automática do saldo em Contratos ativos.
// Cirúrgico: não altera consumo de créditos, planos, financeiro ou Supabase.
// Apenas força a tela já existente a buscar novamente o saldo quando volta a ficar visível.

(() => {
  let installed = false;
  let refreshTimer = null;
  let lastRefreshAt = 0;

  function contractsVisible() {
    const financePanel = document.querySelector('#financePanel');
    const plansTab = document.querySelector('#financePlansTab');
    const contractsTab = document.querySelector('#v129ContractsTab');
    return Boolean(
      financePanel &&
      plansTab &&
      contractsTab &&
      !financePanel.classList.contains('hidden') &&
      !plansTab.classList.contains('hidden') &&
      !contractsTab.classList.contains('hidden')
    );
  }

  function refreshContracts(reason = 'visibility') {
    clearTimeout(refreshTimer);
    refreshTimer = setTimeout(() => {
      if (!contractsVisible()) return;

      // Evita chamadas duplicadas causadas pelo mesmo ciclo de classes/DOM.
      const now = Date.now();
      if (now - lastRefreshAt < 350) return;
      lastRefreshAt = now;

      const button = document.querySelector('[data-v129-plan-mode="contracts"]');
      if (button) button.click();
    }, 120);
  }

  function install() {
    if (installed) return;

    const financePanel = document.querySelector('#financePanel');
    const plansTab = document.querySelector('#financePlansTab');
    if (!financePanel || !plansTab) return;

    installed = true;

    // Quando volta para Financeiro ou para a aba Planos.
    const observer = new MutationObserver(() => refreshContracts('visibility'));
    observer.observe(financePanel, { attributes: true, attributeFilter: ['class'] });
    observer.observe(plansTab, { attributes: true, attributeFilter: ['class'] });

    // Cliques de navegação: cobre também situações em que a classe já estava no mesmo estado.
    document.addEventListener('click', event => {
      if (
        event.target.closest('[data-team-panel="finance"]') ||
        event.target.closest('[data-finance-tab="plans"]') ||
        event.target.closest('[data-v129-plan-mode="contracts"]')
      ) {
        refreshContracts('click');
      }
    }, true);

    // Se o navegador/app volta do segundo plano com Contratos ativos aberto,
    // atualiza o saldo em vez de manter o snapshot antigo.
    document.addEventListener('visibilitychange', () => {
      if (!document.hidden) refreshContracts('visibilitychange');
    });
    window.addEventListener('focus', () => refreshContracts('focus'));

    refreshContracts('install');
  }

  // v12.9 injeta "Contratos ativos" dinamicamente; esperamos sem tocar na lógica dela.
  const bootObserver = new MutationObserver(() => {
    if (document.querySelector('#financePlansTab') && document.querySelector('[data-v129-plan-mode="contracts"]')) {
      install();
      bootObserver.disconnect();
    }
  });
  bootObserver.observe(document.documentElement, { childList: true, subtree: true });

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', install, { once: true });
  } else {
    install();
  }

  setTimeout(install, 500);
  setTimeout(install, 1500);
})();
