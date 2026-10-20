// Barberium · troca de versão (etapa 4, 20/10/2026). Carregado pelo site do cliente e pela Área da Equipe.
//
// Cada publicação carimba a versão na página (<meta name="barberium-versao">) e em /versao.json.
// Um celular que deixou o site aberto em segundo plano continua com a versão antiga na memória.
// Este script confere se saiu uma versão nova e recarrega a página sozinho, mas só num momento
// em que ninguém está no meio de alguma coisa:
//   - quando a pessoa volta para o site depois de 10 minutos ou mais fora dele; ou
//   - quando a página está aberta na tela, mas ninguém mexe nela há 30 minutos;
//   - e nunca com uma janela aberta, um campo sendo preenchido ou um agendamento em andamento.
// Se a recarga não trouxer a versão nova (algum cache no caminho), ele não tenta de novo nesta aba.
(() => {
  const meta = document.querySelector('meta[name="barberium-versao"]');
  const atual = meta ? meta.content : '';
  if (!/^[0-9a-f]{7,40}$/i.test(atual)) return; // página sem carimbo (fora de uma publicação)

  const origem = document.currentScript ? document.currentScript.src : location.href;
  const urlVersao = new URL('../versao.json', origem).href;
  const urlRaiz = new URL('../', origem).href;
  const CHAVE = 'barberium:recarregou-para-versao';
  const FORA_MINIMO = 10 * 60 * 1000;
  const PARADA_MINIMO = 30 * 60 * 1000;
  const CONFERIR_A_CADA = 10 * 60 * 1000;

  let publicada = '';
  let ultimaConferencia = 0;
  let escondidaDesde = document.visibilityState === 'hidden' ? Date.now() : 0;
  let ultimoToque = Date.now();

  const ler = (k) => { try { return sessionStorage.getItem(k); } catch { return null; } };
  const gravar = (k, v) => { try { sessionStorage.setItem(k, v); } catch { /* sem sessionStorage */ } };

  async function conferir() {
    ultimaConferencia = Date.now();
    try {
      const r = await fetch(urlVersao, { cache: 'no-store' });
      if (!r.ok) return publicada;
      const dados = await r.json();
      if (dados && typeof dados.versao === 'string') publicada = dados.versao;
    } catch { /* sem internet: tenta na próxima */ }
    return publicada;
  }

  function ocupada() {
    // Campo de texto, data ou lista com o cursor dentro.
    const foco = document.activeElement;
    if (foco && foco.matches && foco.matches('input, textarea, select, [contenteditable=""], [contenteditable="true"]')) return true;
    // A janela das duas áreas (#modalBackdrop) aberta: finalizar atendimento, cancelar, editar etc.
    const janela = document.getElementById('modalBackdrop');
    if (janela && janela.getClientRects().length > 0) return true;
    // Site do cliente no meio de um agendamento.
    if (document.querySelector('.view.active[data-view="booking"]')) return true;
    return false;
  }

  async function recarregarSePuder() {
    if (!publicada || publicada === atual) return false;
    if (ler(CHAVE) === publicada) return false; // já recarregou para esta versão e não adiantou
    if (document.visibilityState !== 'visible' || ocupada()) return false;
    gravar(CHAVE, publicada);
    // Primeiro deixa o service worker novo assumir (até 5 s), depois recarrega. Recarregar no
    // meio da troca faz o Chrome manter o service worker antigo até a próxima oportunidade.
    try {
      const reg = await navigator.serviceWorker?.getRegistration(urlRaiz);
      if (reg) {
        await reg.update();
        const novo = reg.installing || reg.waiting;
        if (novo) {
          await new Promise((pronto) => {
            const limite = setTimeout(pronto, 5000);
            const ver = () => {
              if (novo.state === 'activated' || novo.state === 'redundant') { clearTimeout(limite); pronto(); }
            };
            novo.addEventListener('statechange', ver);
            ver();
          });
        }
      }
    } catch { /* segue mesmo assim */ }
    // A pessoa pode ter começado algo durante a espera: confere de novo antes de recarregar.
    if (document.visibilityState !== 'visible' || ocupada()) {
      try { sessionStorage.removeItem(CHAVE); } catch { /* */ }
      return false;
    }
    location.reload();
    return true;
  }

  document.addEventListener('visibilitychange', async () => {
    if (document.visibilityState === 'hidden') { escondidaDesde = Date.now(); return; }
    const fora = escondidaDesde ? Date.now() - escondidaDesde : 0;
    escondidaDesde = 0;
    await conferir();
    if (fora >= FORA_MINIMO) await recarregarSePuder();
  });

  for (const ev of ['pointerdown', 'keydown', 'touchstart', 'wheel', 'scroll']) {
    addEventListener(ev, () => { ultimoToque = Date.now(); }, { passive: true, capture: true });
  }

  setInterval(async () => {
    if (document.visibilityState !== 'visible') return;
    if (Date.now() - ultimaConferencia >= CONFERIR_A_CADA) await conferir();
    if (Date.now() - ultimoToque >= PARADA_MINIMO) await recarregarSePuder();
  }, 60 * 1000);

  // Ponto de consulta para diagnóstico (console do navegador): __barberiumVersao
  window.__barberiumVersao = { atual, publicada: () => publicada, conferir };
})();
