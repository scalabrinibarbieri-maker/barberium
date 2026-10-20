# Como publicar uma mudança no Barberium

Desde a etapa 2 (19/10/2026), toda mudança passa pelo **teste** antes de chegar na **produção**. Enviar arquivos para o GitHub não publica mais nada no site real.

## 1. Enviar a mudança

Na página do repositório, toque em **Add file → Upload files**.

- **Pacote** (`pacote-*.zip`): envie na página principal, sem descompactar.
- **Arquivos de `.github/workflows`**: envie direto naquela pasta.

O GitHub roda **Publicar no teste** sozinho, e leva uns 8 minutos. Para acompanhar, abra a aba **Actions**.

Desde a etapa 3, ele também testa sozinho o banco (agendamento, cancelamento, comissões, caixa, datas e isolamento entre barbearias) e o site de teste num navegador, como cliente, barbeiro e ADM. Se algum teste ficar vermelho, veja **Se um teste ficar vermelho**, mais abaixo.

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

Só depois disso ele aplica as mudanças no banco e publica o site. Se qualquer passo falhar, ele para ali. No fim, ele espera o site real trocar de versão e confere se trocou.

## Qual versão está no ar

Desde a etapa 4, cada publicação tem um número de versão: as 7 primeiras letras do código do commit. Para ver qual está no ar, abra:

- produção: **https://scalabrinibarbiere.com/versao.json**
- teste: **https://staging.barberium.pages.dev/versao.json**

Quem abre o site do zero já recebe a versão nova. O celular que estava com o site aberto troca sozinho:

- quando a pessoa volta para o site depois de 10 minutos ou mais fora dele;
- ou quando a tela fica 30 minutos aberta sem ninguém mexer.

Ele nunca troca no meio de um agendamento, com uma janela aberta ou com alguém digitando. Nesses casos, espera a próxima vez.

## Se um teste ficar vermelho

Abra a rodada vermelha em **Actions** e veja qual parte falhou:

| Parte que falhou | O que fazer |
| --- | --- |
| **Testes de caracterização** | Alguma coisa mudou o jeito de o sistema funcionar. Me mande um print do resumo da rodada (ele lista o teste que falhou). Nada vai para a produção enquanto isso não for resolvido |
| **Testar o site de teste** | Pode ter sido lentidão da internet. Toque em **Re-run jobs → Re-run failed jobs** uma vez. Se falhar de novo, me mande um print. No fim da rodada há um arquivo `relatorio-testes-site` com fotos da tela no momento do erro |

O sinal **~** no resumo não é erro. Ele marca um defeito que já conhecemos e que ainda vai ser corrigido.

## Se algo der errado na produção

- **Site:** no Cloudflare, abra **Workers & Pages → barberium → Deployments**, escolha o deploy anterior e toque em **Rollback to this deployment**. Leva segundos. Se o deploy escolhido for da etapa 4 em diante, os celulares voltam para ele sozinhos, do mesmo jeito que trocam para uma versão nova.
- **Banco:** me chame. A volta é uma migration nova, que passa pelo mesmo caminho: primeiro teste, depois produção.

## O que roda sozinho

| Quando | Workflow | O que faz |
| --- | --- | --- |
| Todo dia, 03h17 | Backup diário do banco | Backup criptografado, guardado por 90 dias |
| Segunda, 06h23 | Banco reproduzível | Confere se alguém mexeu na produção sem migration e roda os testes do banco |
| Segunda e quinta, 07h41 | Publicar no teste | Mantém o banco de teste acordado (o plano grátis dorme depois de uma semana sem uso) e roda todos os testes. Cada rodada marca e cancela 1 horário na Scalabrini de teste |
