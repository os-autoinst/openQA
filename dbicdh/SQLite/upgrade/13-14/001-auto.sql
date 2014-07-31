-- Convert schema '/space/lnussel/git/openQA/script/../dbicdh/_source/deploy/13/001-auto.yml' to '/space/lnussel/git/openQA/script/../dbicdh/_source/deploy/14/001-auto.yml':;

;
BEGIN;

;
ALTER TABLE users ADD COLUMN email text;

;
ALTER TABLE users ADD COLUMN fullname text;

;
ALTER TABLE users ADD COLUMN nickname text;

;

COMMIT;

