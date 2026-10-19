import webpush from 'npm:web-push@3.6.7';

const base = Deno.env.get('SUPABASE_URL')!;
const key = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
async function rpc(name: string, body: Record<string, unknown> = {}) {
  const response = await fetch(`${base}/rest/v1/rpc/${name}`, {
    method: 'POST', headers: { apikey: key, Authorization: `Bearer ${key}`, 'Content-Type': 'application/json' },
    body: JSON.stringify(body), signal: AbortSignal.timeout(10000),
  });
  if (!response.ok) throw new Error(`RPC ${name}: ${response.status}`);
  return response.json();
}
function allowedEndpoint(endpoint: string): boolean {
  try {
    const u = new URL(endpoint);
    return u.protocol === 'https:' && !u.username && !u.password && !u.port && !u.hash &&
      /^(fcm\.googleapis\.com|[a-z0-9-]+\.push\.services\.mozilla\.com|web\.push\.apple\.com|[a-z0-9.-]+\.notify\.windows\.com)$/.test(u.hostname);
  } catch { return false; }
}
// Autenticação própria: segredo aleatório do cron, comparado no Vault por RPC restrita ao service_role.
Deno.serve(async (req: Request) => {
  if (req.method !== 'POST') return new Response('Method not allowed', { status: 405 });
  const secret = req.headers.get('x-barberium-push-key');
  if (!secret || !/^[a-f0-9]{64}$/.test(secret)) return new Response('Unauthorized', { status: 401 });
  try {
    const vapid = await rpc('barberium_push_worker_config', { p_secret: secret });
    if (!vapid) return new Response('Unauthorized', { status: 401 });
    const jobs = [...(await rpc('barberium_booking_claim')).map((j: any) => ({...j, queue:'booking'})), ...(await rpc('barberium_push_claim')).map((j: any) => ({...j, queue:'push'})), ...(await rpc('barberium_wa_claim')).map((j: any) => ({...j, queue:'wa'}))];
    let accepted = 0;
    for (const job of jobs) {
      const delivery = await rpc(`barberium_${job.queue}_delivery`, { p_id: job.id, p_lease: job.lease_id });
      let code = 409;
      if (delivery) {
        code = 400;
        if (allowedEndpoint(delivery.subscription.endpoint)) {
          try {
            // web-push calcula VAPID e criptografia; fetch limita tempo e impede redirecionamentos.
            const details = webpush.generateRequestDetails(delivery.subscription, JSON.stringify(delivery.payload), {
              vapidDetails: vapid, TTL: delivery.ttl, urgency: 'normal', contentEncoding: 'aes128gcm',
              topic: job.id.replaceAll('-', ''),
            });
            const response = await fetch(details.endpoint, { method: 'POST', headers: details.headers,
              body: new Uint8Array(details.body), redirect: 'error', signal: AbortSignal.timeout(8000) });
            code = response.status;
            await response.body?.cancel();
            if (code >= 200 && code < 300) accepted++;
          } catch { code = 0; }
        }
      }
      await rpc(`barberium_${job.queue}_result`, { p_id: job.id, p_lease: job.lease_id, p_code: code });
    }
    return Response.json({ processed: jobs.length, accepted });
  } catch (e) {
    // Não registrar inscrições, credenciais ou conteúdo do cliente.
    console.error('Push worker error', e instanceof Error && e.message.startsWith('RPC ') ? e.message : 'internal');
    return Response.json({ error: 'Push worker temporarily unavailable' }, { status: 503 });
  }
});
