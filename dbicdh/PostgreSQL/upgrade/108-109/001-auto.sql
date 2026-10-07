-- Convert schema '/home/okurz/local/worktrees/openQA-7928/script/../dbicdh/_source/deploy/108/001-auto.yml' to '/home/okurz/local/worktrees/openQA-7928/script/../dbicdh/_source/deploy/109/001-auto.yml':;

;
BEGIN;

;
ALTER TABLE users ADD COLUMN password text;

;

COMMIT;

