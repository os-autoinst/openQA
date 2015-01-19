-- Convert schema '/home/ags/projects/openqa/openqa/script/../dbicdh/_source/deploy/21/001-auto.yml' to '/home/ags/projects/openqa/openqa/script/../dbicdh/_source/deploy/22/001-auto.yml':;

;
BEGIN;

;
ALTER TABLE commands DROP FOREIGN KEY commands_fk_worker_id;

;
DROP TABLE commands;

;

COMMIT;

