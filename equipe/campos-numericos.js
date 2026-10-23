// Barberium · campos de número (etapa 7e, 23/10/2026).
//
// Antes (v12.9, em barberium-v12.9.js): num campo de número com 0, tocar seleciona o 0 e o
// primeiro dígito digitado entra no lugar dele (em vez de virar "05"). Vale para todos os
// campos de número da Área da Equipe. Mesmo comportamento, agora carregado pelo team.js.
//
// E (v12.22, em barberium-v12.17.js): nos valores em reais da comissão de planos, "25.50" vira
// "25,50" ao sair do campo e antes de salvar, porque a conta de reais do team.js lê o ponto como
// separador de milhar (25.50 viraria R$ 2.550,00).

function campoDeNumero(input) {
  return input instanceof HTMLInputElement && (input.type === 'number' || input.inputMode === 'decimal' || input.inputMode === 'numeric');
}
function valeZero(input) {
  if (!campoDeNumero(input)) return false;
  const bruto = String(input.value || '').trim().replace(',', '.');
  return bruto !== '' && Number.isFinite(Number(bruto)) && Number(bruto) === 0;
}
document.addEventListener('focusin', (e) => {
  const input = e.target;
  if (!valeZero(input)) return;
  requestAnimationFrame(() => { try { input.select(); } catch { /* campo sem seleção */ } });
});
document.addEventListener('beforeinput', (e) => {
  const input = e.target;
  if (!valeZero(input) || e.inputType !== 'insertText' || !/^\d$/.test(e.data || '')) return;
  e.preventDefault();
  input.value = e.data;
  input.dispatchEvent(new Event('input', { bubbles: true }));
});

// "25.50" → "25,50"; qualquer outra coisa fica como está (vírgula, milhar, inteiro).
export function virgulaNosCentavos(valor) {
  const s = String(valor ?? '').trim();
  if (!s || s.includes(',')) return s;
  if ((s.match(/\./g) || []).length !== 1) return s;
  const [esquerda, direita] = s.split('.');
  if (!/^-?\d+$/.test(esquerda) || !/^\d{1,2}$/.test(direita)) return s;
  return `${esquerda},${direita}`;
}
export function corrigirCentavos(input) {
  if (!input) return;
  const novo = virgulaNosCentavos(input.value);
  if (novo !== input.value) input.value = novo;
}
