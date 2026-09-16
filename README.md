# Barberium — Scalabrini Barbieri (Cliente v5 / Backend real)

Esta versão conecta a área do cliente ao Supabase real do Barberium.

## Agora é compartilhado entre aparelhos

- catálogo e adicionais vêm do banco;
- horários são consultados no servidor;
- conflitos entre clientes são bloqueados no banco;
- novos agendamentos são gravados no Supabase;
- cancelamento e reagendamento são reais;
- histórico é carregado do backend;
- o dispositivo recebe um token aleatório para reconhecer o cliente sem senha.

## Estrutura preparada para SaaS

O banco é multiempresa e já possui tabelas para barbearias, unidades, profissionais, serviços, adicionais, clientes, horários, bloqueios, agendamentos e membros administrativos.

## Ainda pendente

- painel ADM visual;
- recuperação de acesso por código no WhatsApp;
- alteração de telefone com confirmação;
- automações e notificações via WhatsApp.
