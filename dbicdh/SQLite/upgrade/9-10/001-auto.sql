-- Convert schema '/space/lnussel/git/openQA/script/../dbicdh/_source/deploy/9/001-auto.yml' to '/space/lnussel/git/openQA/script/../dbicdh/_source/deploy/10/001-auto.yml':;

;
BEGIN;

;
CREATE TABLE machine_settings (
  id INTEGER PRIMARY KEY NOT NULL,
  machine_id integer NOT NULL,
  key text NOT NULL,
  value text NOT NULL,
  t_created timestamp,
  t_updated timestamp,
  FOREIGN KEY (machine_id) REFERENCES machines(id) ON DELETE CASCADE ON UPDATE CASCADE
);

;
CREATE INDEX machine_settings_idx_machine_id ON machine_settings (machine_id);

;
CREATE UNIQUE INDEX machine_settings_machine_id_key ON machine_settings (machine_id, key);

;
CREATE TABLE product_settings (
  id INTEGER PRIMARY KEY NOT NULL,
  product_id integer NOT NULL,
  key text NOT NULL,
  value text NOT NULL,
  t_created timestamp,
  t_updated timestamp,
  FOREIGN KEY (product_id) REFERENCES products(id) ON DELETE CASCADE ON UPDATE CASCADE
);

;
CREATE INDEX product_settings_idx_product_id ON product_settings (product_id);

;
CREATE UNIQUE INDEX product_settings_product_id_key ON product_settings (product_id, key);

;

COMMIT;

