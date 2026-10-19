create index if not exists idx_customers_preferred_unit on public.customers(preferred_unit_id);
create index if not exists idx_campaign_recipients_customer on public.client_campaign_recipients(customer_id);
create index if not exists idx_campaign_templates_created_by on public.client_campaign_templates(created_by);
create index if not exists idx_campaigns_created_by on public.client_campaigns(created_by);

