# Barberium v12.1 — Grade de horários por profissional

## Regra
A unidade continua possuindo `slot_minutes` como padrão. Cada profissional pode:

- **Usar padrão da unidade**: não grava override;
- **Personalizar**: grava `professionals.settings.slot_minutes` entre 5 e 120 minutos.

A configuração muda somente os **horários possíveis de início** exibidos na agenda. A duração do serviço continua sendo determinada pelo serviço/vínculo do profissional.

## Backend
- `barberium.effective_slot_minutes(professional_id)` resolve override -> padrão da unidade -> 10 min.
- `barberium_staff_save_professional_agenda_settings` é exclusivo de owner/admin.
- `barberium_get_available_slots` e `barberium_staff_available_slots` usam o valor efetivo.
- RPC de gravação não é executável por `anon`.

## Interface
Em **Configurações > Profissionais > Editar profissional > Agenda** o ADM escolhe entre herdar o padrão ou definir um intervalo próprio.
