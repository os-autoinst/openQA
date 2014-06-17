-- Convert schema '/space/lnussel/git/openQA/script/../dbicdh/_source/deploy/11/001-auto.yml' to '/space/lnussel/git/openQA/script/../dbicdh/_source/deploy/12/001-auto.yml':;

;
BEGIN;

;
CREATE INDEX job_settings_kv_index ON job_settings (key, value);

;

COMMIT;

