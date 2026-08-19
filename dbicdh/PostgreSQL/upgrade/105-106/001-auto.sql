-- Convert schema '/home/okurz/local/os-autoinst/openQA/script/../dbicdh/_source/deploy/105/001-auto.yml' to '/home/okurz/local/os-autoinst/openQA/script/../dbicdh/_source/deploy/106/001-auto.yml':;

;
BEGIN;

;
ALTER TABLE job_group_parents ADD COLUMN always_show_version boolean;

;
ALTER TABLE job_groups ADD COLUMN always_show_version boolean;

;

COMMIT;

