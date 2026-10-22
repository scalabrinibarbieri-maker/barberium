// Barberium · convite do dono de uma barbearia nova (painel do dono do SaaS, 21/10/2026).
//
// O painel chama esta função com o login do dono do Barberium e o id do convite. Ela:
//   1. confere no banco, com o login de quem chamou, se é dono do Barberium e lê o convite
//      (a própria função do banco recusa quem não é dono);
//   2. cria o login do convidado no Supabase Auth sem mandar e-mail (generate_link). Se o
//      e-mail já tem login, gera um link de nova senha (recovery) para o mesmo login;
//   3. liga o login à barbearia do convite (função do banco que só o servidor pode chamar);
//   4. devolve o código do link. O painel monta o endereço e manda pelo WhatsApp.
// Não usa biblioteca: só fetch, para rodar igual no Supabase (Deno) e nos testes (Node).

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, apikey, content-type, x-client-info',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

const resposta = (status, corpo) => new Response(JSON.stringify(corpo), { status, headers: { ...CORS, 'Content-Type': 'application/json' } });

async function chamar(url, init) {
  const r = await fetch(url, { ...init, signal: AbortSignal.timeout(15000) });
  const texto = await r.text();
  let dados = null;
  try { dados = texto ? JSON.parse(texto) : null; } catch { dados = texto; }
  return { status: r.status, ok: r.ok, dados };
}

const mensagem = (d) => String(d?.message || d?.msg || d?.error_description || d?.error || '');

// Chave do servidor: as novas (sb_secret_...) vão só no apikey; a antiga (JWT do service_role),
// no apikey e no Authorization, como na função barberium-push.
const cabecalhosDoServidor = (chave) => (chave.startsWith('sb_')
  ? { apikey: chave, 'Content-Type': 'application/json' }
  : { apikey: chave, Authorization: `Bearer ${chave}`, 'Content-Type': 'application/json' });

export async function tratarConvite(req, env) {
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: CORS });
  if (req.method !== 'POST') return resposta(405, { message: 'Use POST' });
  const token = (req.headers.get('authorization') || '').replace(/^Bearer\s+/i, '');
  if (!token || token.split('.').length !== 3) return resposta(401, { message: 'Entre no painel de novo' });
  let corpo;
  try { corpo = await req.json(); } catch { return resposta(400, { message: 'Pedido inválido' }); }
  const convite = String(corpo?.convite || '');
  if (!UUID.test(convite)) return resposta(400, { message: 'Convite inválido' });

  const chavePublica = req.headers.get('apikey') || env.anonKey;
  const rpc = (nome, params, cabecalhos) => chamar(`${env.url}/rest/v1/rpc/${nome}`, {
    method: 'POST', headers: cabecalhos, body: JSON.stringify(params),
  });
  const comoQuemChamou = { apikey: chavePublica, Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' };

  try {
    // 1. Quem chamou é dono do Barberium? (a função do banco confere e lê o convite)
    const det = await rpc('barberium_platform_invite_detail', { p_invite: convite }, comoQuemChamou);
    if (!det.ok) {
      const m = mensagem(det.dados);
      if (det.status === 401 || /JWT|autenticado/i.test(m)) return resposta(401, { message: 'Entre no painel de novo' });
      if (/somente para o dono/i.test(m)) return resposta(403, { message: 'Acesso somente para o dono do Barberium' });
      if (/não encontrado/i.test(m)) return resposta(404, { message: 'Convite não encontrado' });
      throw new Error(`detalhe do convite: ${det.status}`);
    }
    const c = det.dados;
    if (c.barbershop_status !== 'active') return resposta(409, { message: 'A barbearia não está ativa' });

    // 2. Login do convidado, sem e-mail.
    const gerar = (type) => chamar(`${env.url}/auth/v1/admin/generate_link`, {
      method: 'POST',
      headers: cabecalhosDoServidor(env.serviceKey),
      body: JSON.stringify({ type, email: c.email, data: type === 'invite' ? { full_name: c.full_name } : undefined }),
    });
    let link = await gerar('invite');
    let tipo = 'invite';
    if (!link.ok && (link.status === 422 || /already been registered|email_exists/i.test(mensagem(link.dados) + (link.dados?.code || link.dados?.error_code || '')))) {
      link = await gerar('recovery');
      tipo = 'recovery';
    }
    if (!link.ok) throw new Error(`generate_link: ${link.status}`);
    const d = link.dados || {};
    const usuario = d.id || d.user?.id;
    const codigo = d.hashed_token || d.properties?.hashed_token;
    tipo = d.verification_type || d.properties?.verification_type || tipo;
    if (!usuario || !codigo) throw new Error('generate_link sem usuário ou código');

    // 3. Liga o login à barbearia.
    const ligar = await rpc('barberium_platform_link_invite', { p_invite: convite, p_auth_user: usuario }, cabecalhosDoServidor(env.serviceKey));
    if (!ligar.ok) throw new Error(`ligar convite: ${ligar.status}`);

    return resposta(200, {
      codigo, tipo, email: c.email, nome: c.full_name, whatsapp: c.whatsapp || null,
      barbearia: c.barbershop_name, slug: c.barbershop_slug, host: c.host,
    });
  } catch (e) {
    // Sem e-mail, token ou dado do convidado no log.
    console.error('barberium-convite:', e instanceof Error ? e.message : 'erro');
    return resposta(503, { message: 'Não foi possível gerar o convite agora. Tente de novo.' });
  }
}
