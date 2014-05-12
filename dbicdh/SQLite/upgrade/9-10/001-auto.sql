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

DROP TRIGGER IF EXISTS trigger_machine_settings_t_created;
CREATE TRIGGER trigger_machine_settings_t_created after insert on machine_settings BEGIN UPDATE machine_settings SET t_created = datetime('now') WHERE _rowid_ = NEW._rowid_; END;
DROP TRIGGER IF EXISTS trigger_machine_settings_t_updated;
CREATE TRIGGER trigger_machine_settings_t_updated after update on machine_settings BEGIN UPDATE machine_settings SET t_updated = datetime('now') WHERE _rowid_ = NEW._rowid_; END;
DROP TRIGGER IF EXISTS trigger_machines_t_created;
CREATE TRIGGER trigger_machines_t_created after insert on machines BEGIN UPDATE machines SET t_created = datetime('now') WHERE _rowid_ = NEW._rowid_; END;
DROP TRIGGER IF EXISTS trigger_machines_t_updated;
CREATE TRIGGER trigger_machines_t_updated after update on machines BEGIN UPDATE machines SET t_updated = datetime('now') WHERE _rowid_ = NEW._rowid_; END;
DROP TRIGGER IF EXISTS trigger_product_settings_t_created;
CREATE TRIGGER trigger_product_settings_t_created after insert on product_settings BEGIN UPDATE product_settings SET t_created = datetime('now') WHERE _rowid_ = NEW._rowid_; END;
DROP TRIGGER IF EXISTS trigger_product_settings_t_updated;
CREATE TRIGGER trigger_product_settings_t_updated after update on product_settings BEGIN UPDATE product_settings SET t_updated = datetime('now') WHERE _rowid_ = NEW._rowid_; END;
DROP TRIGGER IF EXISTS trigger_products_t_created;
CREATE TRIGGER trigger_products_t_created after insert on products BEGIN UPDATE products SET t_created = datetime('now') WHERE _rowid_ = NEW._rowid_; END;
DROP TRIGGER IF EXISTS trigger_products_t_updated;
CREATE TRIGGER trigger_products_t_updated after update on products BEGIN UPDATE products SET t_updated = datetime('now') WHERE _rowid_ = NEW._rowid_; END;

COMMIT;

