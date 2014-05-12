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

COMMIT;

