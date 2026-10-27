// Barberium · site do cliente · entrada animada da capa (logo, nome e "Agendar agora").
// Era a v12.44, dentro do remendo barberium-client-v12.24.js: ela vigiava a página esperando a
// tela de abertura sair. Agora o app.js chama tocarCapa quando revela o site. O logo e o
// brilho dele (.v1244-logo-stage) vêm prontos no index.html; o estilo está em cliente/abertura.css.

const reduzido = window.matchMedia?.('(prefers-reduced-motion: reduce)')?.matches === true;
let comecou = false;

function terminar() {
  const conteudo = document.querySelector('.hero-content');
  if (!conteudo) return;
  conteudo.classList.remove('v1244-intro', 'v1244-play');
  conteudo.classList.add('v1244-done');
}

// Esconde o conteúdo da capa até a entrada começar.
export function prepararCapa() {
  const conteudo = document.querySelector('.hero-content');
  if (!conteudo) return;
  const logo = conteudo.querySelector('.hero-logo');
  const brilho = conteudo.querySelector('.v1244-logo-glint');
  if (logo && brilho) brilho.src = logo.currentSrc || logo.src;
  if (!conteudo.classList.contains('v1244-done')) conteudo.classList.add('v1244-intro');
  // Garantia: o conteúdo nunca fica preso invisível.
  setTimeout(() => { if (!comecou) tocarCapa(); }, 5200);
}

export function tocarCapa() {
  if (comecou) return;
  comecou = true;
  const conteudo = document.querySelector('.hero-content');
  if (!conteudo) return;
  if (reduzido) { terminar(); return; }
  requestAnimationFrame(() => requestAnimationFrame(() => conteudo.classList.add('v1244-play')));
  setTimeout(terminar, 1650);
}
