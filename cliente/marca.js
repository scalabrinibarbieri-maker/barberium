// Barberium · site do cliente · marca da barbearia e manutenção (etapa 7h, parte 1).
//
// Antes, o remendo barberium-client-v12.24.js (v12.24 a v12.47) buscava o catálogo de novo só
// para isto, injetava o próprio CSS e vigiava a página inteira para reescrever textos. Agora o
// app.js busca o catálogo uma vez e chama aplicarMarca com ele antes de mostrar o site.
//
// A tela de abertura (index.html) cobre o site até revelarSite. A capa (.hero-bg) fica
// invisível até a foto certa carregar, para não aparecer a foto padrão antes da da barbearia.

const $ = (s, r = document) => r.querySelector(s);
const setText = (el, value) => { if (el && value != null && el.textContent !== String(value)) el.textContent = String(value); };
const setSrc = (el, value) => { if (el && value && el.getAttribute('src') !== value) el.setAttribute('src', value); };
const esc = (v) => String(v ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#039;' }[c]));

const SPLASH_PENDING_CLASS = 'barberium-splash-pending';
const HERO_PENDING_CLASS = 'barberium-hero-pending';
const LOGO_HOST_KEY = `barberium:brand-logo:${location.hostname}`;
const MIN_SPLASH_MS = 360;
// Imagens padrão, relativas à página (index.html), não a este arquivo. O caminho vai sem ponto e barra
// no texto para o deploy (conferir_referencias.py) conferir o arquivo na raiz do site.
const daPagina = (caminho) => `./${caminho}`;
const LOGO_PADRAO = daPagina('assets/logo-sb.webp');
const CAPA_PADRAO = daPagina('assets/barbearia.webp');
const MENSAGEM_PADRAO = 'Estamos realizando uma atualização. Os agendamentos online voltarão em breve.';

document.documentElement.classList.add(HERO_PENDING_CLASS);

// Logo da tela de abertura: guardado por barbearia/unidade e, para o index.html achar antes de
// saber a barbearia, também pelo endereço do site.
function guardarLogo(logo, tenant) {
  if (!logo) return;
  try {
    localStorage.setItem(`barberium:brand-logo:${tenant.barbershopSlug}:${tenant.unitSlug}`, logo);
    localStorage.setItem(LOGO_HOST_KEY, logo);
  } catch {}
  setSrc($('#barberiumSplashLogo'), logo);
}

function esperarImagem(img, url, prazo = 5000) {
  return new Promise((resolve) => {
    if (!img || !url) { resolve(false); return; }
    let feito = false;
    const fim = (ok) => {
      if (feito) return;
      feito = true;
      clearTimeout(relogio);
      img.removeEventListener('load', aoCarregar);
      img.removeEventListener('error', aoFalhar);
      resolve(ok);
    };
    const aoCarregar = () => fim(true);
    const aoFalhar = () => fim(false);
    const relogio = setTimeout(() => fim(false), prazo);
    img.addEventListener('load', aoCarregar, { once: true });
    img.addEventListener('error', aoFalhar, { once: true });
    if (img.getAttribute('src') !== url) img.setAttribute('src', url);
    if (img.complete && img.naturalWidth > 0) queueMicrotask(() => fim(true));
  });
}

// Só libera a capa depois da foto certa estar pronta (ou da padrão, se a da barbearia falhar).
async function prepararCapa(url) {
  const capa = $('.hero-bg');
  if (capa) {
    const ok = await esperarImagem(capa, url, 5000);
    if (!ok && url !== CAPA_PADRAO) await esperarImagem(capa, CAPA_PADRAO, 2500);
  }
  document.documentElement.classList.remove(HERO_PENDING_CLASS);
}

const subtituloPadrao = (unit) => String(unit?.name || '').replace(/\s+[—–-]\s+/, ' • ');

function telefoneVisivel(v = '') {
  const digits = String(v).replace(/\D/g, '');
  if (digits.startsWith('55') && digits.length >= 12) {
    const local = digits.slice(2);
    const ddd = local.slice(0, 2);
    const number = local.slice(2);
    if (number.length === 9) return `+55 ${ddd} ${number.slice(0, 5)}-${number.slice(5)}`;
    if (number.length === 8) return `+55 ${ddd} ${number.slice(0, 4)}-${number.slice(4)}`;
  }
  return v || '';
}

export function linkDoWhatsapp(v = '') {
  const digits = String(v).replace(/\D/g, '');
  return digits ? `https://wa.me/${digits}` : '';
}

function destaques(value) {
  if (Array.isArray(value)) return value.map((v) => String(v || '').trim()).filter(Boolean);
  if (typeof value === 'string') return value.split(/\r?\n/).map((v) => v.trim()).filter(Boolean);
  return [
    'Cortes, barba tradicional e barba express',
    'Combos completos com barba, sobrancelha e barboterapia',
    'Barboterapia, sobrancelha, pezinho detalhes e cabeça raspada',
  ];
}

// Textos da seção "Nossos serviços" da página inicial (Ajustes → Área do cliente).
function aplicarApresentacao(st = {}) {
  const kicker = String(st.client_services_kicker || 'Experiências').trim();
  const titulo = String(st.client_services_title || 'Nossos serviços').trim();
  const intro = String(st.client_services_intro || 'Trabalhamos com uma seleção premium de atendimentos para manter sua experiência mais prática e elegante. Ao tocar em Agendar agora, você verá todos os serviços disponíveis com seus respectivos valores e duração.').trim();
  const itens = destaques(st.client_services_bullets);
  const cta = String(st.client_services_cta || 'Ver serviços e agendar →').trim();
  setText($('.home-section .section-title span'), kicker);
  setText($('.home-section .section-title h2'), titulo);
  setText($('.services-summary-card > p'), intro);
  const lista = $('.services-summary-list');
  if (lista) {
    lista.innerHTML = '';
    for (const item of itens) {
      const li = document.createElement('li');
      li.textContent = item;
      lista.appendChild(li);
    }
    lista.hidden = itens.length === 0;
  }
  setText($('.inline-book-button'), cta);
}

// Tela de manutenção por cima do site (o banco também recusa agendar e reagendar).
export function mostrarManutencao({ shopName, unitName, logo, whatsapp, message }) {
  document.body.classList.add('barberium-maintenance-active');
  document.title = `${shopName} • Temporariamente indisponível`;
  let tela = document.getElementById('barberiumMaintenance');
  if (!tela) {
    tela = document.createElement('section');
    tela.id = 'barberiumMaintenance';
    tela.setAttribute('role', 'status');
    tela.setAttribute('aria-live', 'polite');
    document.body.appendChild(tela);
  }
  const wa = linkDoWhatsapp(whatsapp);
  tela.innerHTML = `
      <div class="v1247-maintenance-card">
        <img class="v1247-maintenance-logo" src="${esc(logo)}" alt="${esc(shopName)}">
        <div class="v1247-maintenance-line"></div>
        <p class="v1247-maintenance-kicker">Área do cliente</p>
        <h1>Agendamentos temporariamente indisponíveis.</h1>
        <p class="v1247-maintenance-copy">${esc(message)}</p>
        <p class="v1247-maintenance-unit">${esc(unitName)}</p>
        ${wa ? `<div class="v1247-maintenance-actions"><a class="v1247-maintenance-wa" href="${wa}" target="_blank" rel="noopener">Falar pelo WhatsApp</a></div>` : ''}
        <p class="v1247-maintenance-foot">Barberium • acesso temporariamente suspenso</p>
      </div>
    `;
  const app = document.querySelector('.app-shell');
  if (app) {
    app.setAttribute('aria-hidden', 'true');
    try { app.inert = true; } catch {}
  }
}

// Sem catálogo (barbearia fora do ar ou sem conexão): a mesma tela, com a mensagem padrão.
export function mostrarManutencaoSemCatalogo(tenant) {
  mostrarManutencao({
    shopName: tenant.barbershopName,
    unitName: tenant.unitName || '',
    logo: window.__barberiumSplashLogo || LOGO_PADRAO,
    whatsapp: '',
    message: MENSAGEM_PADRAO,
  });
  document.documentElement.classList.remove(HERO_PENDING_CLASS);
}

// Aplica nome, unidade, logo, capa, textos e WhatsApp da barbearia do catálogo. Devolve
// { manutencao, nomes, capaPronta }: capaPronta resolve quando a foto da capa carregou.
export function aplicarMarca(catalog, tenant) {
  const b = catalog?.barbershop || {};
  const u = catalog?.unit || {};
  const st = u.settings || {};
  const shopName = String(b.name || tenant.barbershopName || '').trim();
  const unitName = String(u.name || tenant.unitName || '').trim();
  const nomes = { shopName, unitName, whatsapp: u.whatsapp || '' };
  const logo = String(st.client_logo_url || LOGO_PADRAO).trim();
  guardarLogo(logo, tenant);

  // O banco diz se a unidade está em manutenção (a mesma regra que recusa agendar). Sem a
  // resposta do banco nova: a chave ausente vale como ligada, como sempre foi.
  const manutencao = typeof u.maintenance === 'boolean'
    ? u.maintenance
    : (st.client_maintenance_mode == null ? true : st.client_maintenance_mode === true);
  if (manutencao) {
    mostrarManutencao({ shopName, unitName, logo, whatsapp: u.whatsapp, message: String(st.client_maintenance_message || MENSAGEM_PADRAO).trim() });
    document.documentElement.classList.remove(HERO_PENDING_CLASS);
    return { manutencao: true, nomes, capaPronta: Promise.resolve() };
  }

  const heroLabel = String(st.client_hero_label || shopName).trim();
  const heroTitle = String(st.client_hero_title || 'Agende seu horário.').trim();
  document.title = `${shopName} • ${u.city || unitName}`;
  $('meta[name="description"]')?.setAttribute('content', `${heroTitle.replace(/\.$/, '')} na ${shopName} — ${unitName}.`);
  setText($('.brand-button strong'), shopName);
  setText($('.brand-button small'), String(st.client_header_subtitle || subtituloPadrao(u) || unitName).trim());
  setText($('.hero-unit'), heroLabel);
  setText($('.hero-content h1'), heroTitle);
  setText($('.unit-card h2'), unitName);
  setSrc($('.mini-logo'), logo);
  setSrc($('.hero-logo'), logo);
  setSrc($('.unit-logo-wrap img'), logo);
  const capa = $('.hero-bg');
  if (capa) capa.alt = `Interior da ${shopName}`;
  const heroLogo = $('.hero-logo');
  if (heroLogo) heroLogo.alt = shopName;
  // O brilho do logo da capa (cliente/capa.js) é uma cópia do logo.
  const brilho = $('.v1244-logo-glint');
  if (brilho && heroLogo) brilho.src = heroLogo.src;
  if (u.whatsapp) setText($('.unit-info > div:nth-child(2) strong'), telefoneVisivel(u.whatsapp));
  const linkWa = $('.unit-actions a[href*="wa.me"]');
  const wa = linkDoWhatsapp(u.whatsapp);
  if (linkWa && wa) linkWa.href = wa;
  const mapa = $('.unit-actions a[href*="maps"]');
  if (mapa && u.maps_url) mapa.href = u.maps_url;
  aplicarApresentacao(st);
  setText($('[data-view="profile"] .page-heading p'), `Os dados usados nos seus agendamentos da ${shopName}.`);
  return { manutencao: false, nomes, capaPronta: prepararCapa(String(st.client_hero_image_url || CAPA_PADRAO).trim()) };
}

// Tira a tela de abertura (depois de pelo menos 360 ms dela). Resolve quando o site aparece.
export function revelarSite() {
  document.documentElement.classList.remove(HERO_PENDING_CLASS);
  clearTimeout(window.__barberiumSplashFallbackTimer);
  const inicio = Number(window.__barberiumSplashStartedAt) || 0;
  const passou = inicio ? performance.now() - inicio : MIN_SPLASH_MS;
  return new Promise((resolve) => setTimeout(() => {
    document.documentElement.classList.remove(SPLASH_PENDING_CLASS);
    resolve();
  }, Math.max(0, MIN_SPLASH_MS - passou)));
}
