-- Convert schema '/root/openQA/script/../dbicdh/_source/deploy/30/001-auto.yml' to '/root/openQA/script/../dbicdh/_source/deploy/31/001-auto.yml':;

;
BEGIN;

;
SET foreign_key_checks=0;

;
CREATE TABLE `job_networks` (
  `name` text NOT NULL,
  `job_id` integer NOT NULL,
  `vlan` integer NOT NULL,
  INDEX `job_networks_idx_job_id` (`job_id`),
  PRIMARY KEY (`name`, `job_id`),
  CONSTRAINT `job_networks_fk_job_id` FOREIGN KEY (`job_id`) REFERENCES `jobs` (`id`) ON DELETE CASCADE ON UPDATE CASCADE
) ENGINE=InnoDB;

;
SET foreign_key_checks=1;

;

COMMIT;

