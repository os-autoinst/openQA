-- Convert schema '/home/coolo/prod/openQA/script/../dbicdh/_source/deploy/33/001-auto.yml' to '/home/coolo/prod/openQA/script/../dbicdh/_source/deploy/34/001-auto.yml':;

;
BEGIN;

;
SET foreign_key_checks=0;

;
CREATE TABLE `needles` (
  `id` integer NOT NULL auto_increment,
  `filename` text NOT NULL,
  `first_seen_module_id` integer NOT NULL,
  `last_seen_module_id` integer NOT NULL,
  `last_matched_module_id` integer NULL,
  INDEX `needles_idx_first_seen_module_id` (`first_seen_module_id`),
  INDEX `needles_idx_last_matched_module_id` (`last_matched_module_id`),
  INDEX `needles_idx_last_seen_module_id` (`last_seen_module_id`),
  PRIMARY KEY (`id`),
  UNIQUE `needles_filename` (`filename`),
  CONSTRAINT `needles_fk_first_seen_module_id` FOREIGN KEY (`first_seen_module_id`) REFERENCES `job_modules` (`id`),
  CONSTRAINT `needles_fk_last_matched_module_id` FOREIGN KEY (`last_matched_module_id`) REFERENCES `job_modules` (`id`),
  CONSTRAINT `needles_fk_last_seen_module_id` FOREIGN KEY (`last_seen_module_id`) REFERENCES `job_modules` (`id`)
) ENGINE=InnoDB;

;
SET foreign_key_checks=1;

;

COMMIT;

