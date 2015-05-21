-- Convert schema '/space/prod/openQA/script/../dbicdh/_source/deploy/31/001-auto.yml' to '/space/prod/openQA/script/../dbicdh/_source/deploy/32/001-auto.yml':;

;
BEGIN;

;
SET foreign_key_checks=0;

;
CREATE TABLE `job_comments` (
  `id` integer NOT NULL auto_increment,
  `job_id` integer NOT NULL,
  `text` text NOT NULL,
  `user_id` integer NOT NULL,
  `t_created` timestamp NOT NULL,
  `t_updated` timestamp NOT NULL,
  INDEX `job_comments_idx_user_id` (`user_id`),
  INDEX `job_comments_idx_job_id` (`job_id`),
  PRIMARY KEY (`id`),
  CONSTRAINT `job_comments_fk_user_id` FOREIGN KEY (`user_id`) REFERENCES `users` (`id`),
  CONSTRAINT `job_comments_fk_job_id` FOREIGN KEY (`job_id`) REFERENCES `jobs` (`id`) ON DELETE CASCADE ON UPDATE CASCADE
) ENGINE=InnoDB;

;
SET foreign_key_checks=1;

;

COMMIT;

