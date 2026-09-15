# Barberium — Scalabrini Barbieri (Cliente v2)

Segunda versão da área do cliente da **Scalabrini Barbieri — II Unidade, Bragança Paulista**.

## Incluído nesta versão

- Identidade visual premium verde / dourado
- Foto real da unidade na hero
- Logo oficial SB
- Todos os 11 serviços com artes, valores e duração
- Profissionais: Vinicius Nunes e Jean Dalarmi
- Fluxo completo de agendamento
- Agenda inteligente local, respeitando duração do serviço e conflitos do mesmo aparelho
- Dados do cliente sem login e sem senha
- Reconhecimento do cliente no mesmo aparelho
- Próximo agendamento na Home
- Meus horários: próximos e histórico
- Reagendamento com alteração de serviço/profissional/data/hora
- Cancelamento com confirmação
- "Agendar novamente" pelo histórico
- Meu perfil / edição de nome e aniversário
- WhatsApp e Google Maps
- PWA / cache offline

## Importante: protótipo estático atual

Esta versão ainda roda apenas no navegador/GitHub Pages e usa `localStorage`.

Por isso, ainda precisam de backend real:
- agenda compartilhada entre todos os clientes;
- banco de dados multiempresa;
- sincronização entre aparelhos;
- recuperação por código no WhatsApp;
- validação de alteração do número;
- painel administrativo e suas configurações;
- regras de cancelamento/antecedência definidas pelo ADM.

A interface já foi preparada para esses recursos sem exigir login tradicional do cliente.
