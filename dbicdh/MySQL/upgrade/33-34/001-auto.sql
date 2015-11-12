-- Convert schema '/space/prod/openQA/script/../dbicdh/_source/deploy/33/001-auto.yml' to '/space/prod/openQA/script/../dbicdh/_source/deploy/34/001-auto.yml':;

;
BEGIN;

;
SET foreign_key_checks=0;

;
CREATE TABLE `job_module_needles` (
  `needle_id` integer NOT NULL,
  `job_module_id` integer NOT NULL,
  `matched` enum('0','1') NOT NULL DEFAULT '1',
  INDEX `job_module_needles_idx_job_module_id` (`job_module_id`),
  INDEX `job_module_needles_idx_needle_id` (`needle_id`),
  UNIQUE `job_module_needles_needle_id_job_module_id` (`needle_id`, `job_module_id`),
  CONSTRAINT `job_module_needles_fk_job_module_id` FOREIGN KEY (`job_module_id`) REFERENCES `job_modules` (`id`),
  CONSTRAINT `job_module_needles_fk_needle_id` FOREIGN KEY (`needle_id`) REFERENCES `needles` (`id`) ON DELETE CASCADE ON UPDATE CASCADE
) ENGINE=InnoDB;

;
CREATE TABLE `needle_dirs` (
  `id` integer NOT NULL auto_increment,
  `path` text NOT NULL,
  `name` text NOT NULL,
  PRIMARY KEY (`id`),
  UNIQUE `needle_dirs_path` (`path`)
) ENGINE=InnoDB;

;
CREATE TABLE `needles` (
  `id` integer NOT NULL auto_increment,
  `dir_id` integer NOT NULL,
  `filename` text NOT NULL,
  `first_seen_module_id` integer NOT NULL,
  `last_seen_module_id` integer NOT NULL,
  `last_matched_module_id` integer NULL,
  INDEX `needles_idx_dir_id` (`dir_id`),
  INDEX `needles_idx_first_seen_module_id` (`first_seen_module_id`),
  INDEX `needles_idx_last_matched_module_id` (`last_matched_module_id`),
  INDEX `needles_idx_last_seen_module_id` (`last_seen_module_id`),
  PRIMARY KEY (`id`),
  UNIQUE `needles_dir_id_filename` (`dir_id`, `filename`),
  CONSTRAINT `needles_fk_dir_id` FOREIGN KEY (`dir_id`) REFERENCES `needle_dirs` (`id`) ON DELETE CASCADE ON UPDATE CASCADE,
  CONSTRAINT `needles_fk_first_seen_module_id` FOREIGN KEY (`first_seen_module_id`) REFERENCES `job_modules` (`id`),
  CONSTRAINT `needles_fk_last_matched_module_id` FOREIGN KEY (`last_matched_module_id`) REFERENCES `job_modules` (`id`),
  CONSTRAINT `needles_fk_last_seen_module_id` FOREIGN KEY (`last_seen_module_id`) REFERENCES `job_modules` (`id`)
) ENGINE=InnoDB;

;
SET foreign_key_checks=1;

;

COMMIT;

