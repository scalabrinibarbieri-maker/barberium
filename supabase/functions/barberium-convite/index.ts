// Barberium · função de convite do painel do dono do SaaS. A lógica fica em logica.js.
// Publicada com --no-verify-jwt (veja o workflow): o login de quem chama é conferido pelo banco,
// na primeira chamada da lógica, que recusa quem não é dono do Barberium.
import { tratarConvite } from './logica.js';

// Chave do servidor: a nova (SUPABASE_SECRET_KEYS, "default") quando existe; senão a antiga
// (SUPABASE_SERVICE_ROLE_KEY), que o Supabase desliga no fim de 2026.
function chaveDoServidor(): string {
  try {
    const chaves = JSON.parse(Deno.env.get('SUPABASE_SECRET_KEYS') ?? '{}');
    const chave = chaves.default ?? Object.values(chaves)[0];
    if (typeof chave === 'string' && chave) return chave;
  } catch { /* projeto sem as chaves novas */ }
  return Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
}

const env = {
  url: Deno.env.get('SUPABASE_URL')!,
  anonKey: Deno.env.get('SUPABASE_ANON_KEY') ?? '',
  serviceKey: chaveDoServidor(),
};

Deno.serve((req: Request) => tratarConvite(req, env));
