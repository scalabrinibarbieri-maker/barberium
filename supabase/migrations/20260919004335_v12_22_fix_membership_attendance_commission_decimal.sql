
update public.membership_plan_versions
set rules = jsonb_set(
  rules,
  '{commission,service_amounts}',
  jsonb_build_object(
    '39f14bb2-91f6-4164-b98a-55a3c9178d3a',2550,
    'b52690e5-7f8f-429e-b968-67d00baf4aff',2040
  ),
  true
)
where id in (
  '3361e318-b1b2-43ba-b6ac-f455669304c1'::uuid,
  '0f635038-a5ae-475d-b85e-af4ede390427'::uuid
);

update public.commission_entries
set amount_cents=2040
where id='54d1180f-79f0-4862-b218-35fdaaa04353'::uuid
  and status='open'
  and settlement_id is null
  and amount_cents=204000;

update public.commission_entries
set amount_cents=2550
where id='7bf0c67d-d070-48c1-997b-0d5653afff91'::uuid
  and status='open'
  and settlement_id is null
  and amount_cents=255000;

