-- Convert schema '/hdd/openqa-devel/repos/openQA/script/../dbicdh/_source/deploy/99/001-auto.yml' to '/hdd/openqa-devel/repos/openQA/script/../dbicdh/_source/deploy/100/001-auto.yml':;

;
BEGIN;

;
ALTER TABLE scheduled_products ADD COLUMN webhook_id text;

;
CREATE INDEX scheduled_products_idx_webhook_id on scheduled_products (webhook_id);

;

COMMIT;

