-- Convert schema '/hdd/openqa-devel/repos/openQA/script/../dbicdh/_source/deploy/76/001-auto.yml' to '/hdd/openqa-devel/repos/openQA/script/../dbicdh/_source/deploy/77/001-auto.yml':;

;
BEGIN;

;
CREATE TABLE scheduled_products (
  id serial NOT NULL,
  distri text DEFAULT '' NOT NULL,
  version text DEFAULT '' NOT NULL,
  flavor text DEFAULT '' NOT NULL,
  arch text DEFAULT '' NOT NULL,
  build text DEFAULT '' NOT NULL,
  iso text DEFAULT '' NOT NULL,
  status text DEFAULT 'added' NOT NULL,
  settings jsonb NOT NULL,
  results jsonb,
  user_id integer,
  gru_task_id integer,
  minion_job_id integer,
  t_created timestamp NOT NULL,
  t_updated timestamp NOT NULL,
  PRIMARY KEY (id)
);
CREATE INDEX scheduled_products_idx_gru_task_id on scheduled_products (gru_task_id);
CREATE INDEX scheduled_products_idx_user_id on scheduled_products (user_id);

;
ALTER TABLE scheduled_products ADD CONSTRAINT scheduled_products_fk_gru_task_id FOREIGN KEY (gru_task_id)
  REFERENCES gru_tasks (id) ON DELETE SET NULL DEFERRABLE;

;
ALTER TABLE scheduled_products ADD CONSTRAINT scheduled_products_fk_user_id FOREIGN KEY (user_id)
  REFERENCES users (id) ON DELETE SET NULL DEFERRABLE;

;
ALTER TABLE jobs ADD COLUMN scheduled_product_id integer;

;
CREATE INDEX jobs_idx_scheduled_product_id on jobs (scheduled_product_id);

;
ALTER TABLE jobs ADD CONSTRAINT jobs_fk_scheduled_product_id FOREIGN KEY (scheduled_product_id)
  REFERENCES scheduled_products (id) ON DELETE SET NULL ON UPDATE CASCADE DEFERRABLE;

;

COMMIT;

