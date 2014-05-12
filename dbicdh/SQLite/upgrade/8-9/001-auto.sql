-- Convert schema '/space/lnussel/git/openQA/script/../dbicdh/_source/deploy/8/001-auto.yml' to '/space/lnussel/git/openQA/script/../dbicdh/_source/deploy/9/001-auto.yml':;

;
BEGIN;

;
CREATE TABLE test_suite_settings (
  id INTEGER PRIMARY KEY NOT NULL,
  test_suite_id integer NOT NULL,
  key text NOT NULL,
  value text NOT NULL,
  t_created timestamp,
  t_updated timestamp,
  FOREIGN KEY (test_suite_id) REFERENCES test_suites(id) ON DELETE CASCADE ON UPDATE CASCADE
);

;
CREATE INDEX test_suite_settings_idx_test_suite_id ON test_suite_settings (test_suite_id);

;
CREATE UNIQUE INDEX test_suite_settings_test_suite_id_key ON test_suite_settings (test_suite_id, key);

;

DROP TRIGGER IF EXISTS trigger_test_suite_settings_t_created;
CREATE TRIGGER trigger_test_suite_settings_t_created after insert on test_suite_settings BEGIN UPDATE test_suite_settings SET t_created = datetime('now') WHERE _rowid_ = NEW._rowid_; END;
DROP TRIGGER IF EXISTS trigger_test_suite_settings_t_updated;
CREATE TRIGGER trigger_test_suite_settings_t_updated after update on test_suite_settings BEGIN UPDATE test_suite_settings SET t_updated = datetime('now') WHERE _rowid_ = NEW._rowid_; END;

COMMIT;

