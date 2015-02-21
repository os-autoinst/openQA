-- Convert schema '/home/openQA/script/../dbicdh/_source/deploy/24/001-auto.yml' to '/home/openQA/script/../dbicdh/_source/deploy/25/001-auto.yml':;

;
BEGIN;

;
SET foreign_key_checks=0;

;
CREATE TABLE `job_locks` (
  `name` text NOT NULL,
  `owner` integer NOT NULL,
  `locked_by` integer NULL,
  INDEX `job_locks_idx_locked_by` (`locked_by`),
  INDEX `job_locks_idx_owner` (`owner`),
  PRIMARY KEY (`name`, `owner`),
  CONSTRAINT `job_locks_fk_locked_by` FOREIGN KEY (`locked_by`) REFERENCES `jobs` (`id`) ON DELETE CASCADE ON UPDATE CASCADE,
  CONSTRAINT `job_locks_fk_owner` FOREIGN KEY (`owner`) REFERENCES `jobs` (`id`) ON DELETE CASCADE ON UPDATE CASCADE
) ENGINE=InnoDB;

;
SET foreign_key_checks=1;

;

COMMIT;

