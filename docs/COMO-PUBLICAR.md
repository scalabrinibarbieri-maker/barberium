# Como publicar uma mudança no Barberium

Desde a etapa 2 (19/10/2026), toda mudança passa pelo **teste** antes de chegar na **produção**. Enviar arquivos para o GitHub não publica mais nada no site real.

## 1. Enviar a mudança

Na página do repositório, toque em **Add file → Upload files**.

- **Pacote** (`pacote-*.zip`): envie na página principal, sem descompactar.
- **Arquivos de `.github/workflows`**: envie direto naquela pasta.

O GitHub roda **Publicar no teste** sozinho, e leva uns 5 minutos. Para acompanhar, abra a aba **Actions**.

## 2. Conferir no teste

Abra **https://staging.barberium.pages.dev**. O site de teste tem uma faixa laranja escrita **AMBIENTE DE TESTE** e mostra só dados fictícios.

Para entrar na Área da Equipe de teste, abra **https://staging.barberium.pages.dev/equipe/** e use um destes logins:

| Login | Quem é |
| --- | --- |
| `adm.scalabrini@example.com` | ADM da Scalabrini de teste |
| `barbeiro.scalabrini@example.com` | Barbeiro (Vinicius) da Scalabrini de teste |
| `adm.aurora@example.com` | ADM da Barbearia Aurora |

A senha dos três é a que você guardou no segredo `STAGING_SENHA_TESTE`.

No teste você pode agendar, cancelar e mexer à vontade. Nada disso chega nos clientes de verdade.

## 3. Publicar na produção

1. Vá em **Actions → Publicar em produção → Run workflow**.
2. Marque **Já conferi o site de teste**.
3. Toque em **Run workflow**.

Antes de publicar, o GitHub confere três coisas:

- se essa mesma versão passou no teste;
- se o banco de produção está como o repositório diz;
- se as mudanças novas no banco rodam sem erro. Para isso ele faz um ensaio e desfaz tudo.

Só depois disso ele aplica as mudanças no banco e publica o site. Se qualquer passo falhar, ele para ali.

## Se algo der errado na produção

- **Site:** no Cloudflare, abra **Workers & Pages → barberium → Deployments**, escolha o deploy anterior e toque em **Rollback to this deployment**. Leva segundos.
- **Banco:** me chame. A volta é uma migration nova, que passa pelo mesmo caminho: primeiro teste, depois produção.

## O que roda sozinho

| Quando | Workflow | O que faz |
| --- | --- | --- |
| Todo dia, 03h17 | Backup diário do banco | Backup criptografado, guardado por 90 dias |
| Segunda, 06h23 | Banco reproduzível | Confere se alguém mexeu na produção sem migration |
| Segunda e quinta, 07h41 | Publicar no teste | Mantém o banco de teste acordado (o plano grátis dorme depois de uma semana sem uso) |
