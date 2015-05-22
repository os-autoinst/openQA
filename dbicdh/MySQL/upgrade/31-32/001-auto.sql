-- Convert schema '/space/prod/openQA/script/../dbicdh/_source/deploy/31/001-auto.yml' to '/space/prod/openQA/script/../dbicdh/_source/deploy/32/001-auto.yml':;

;
BEGIN;

;
SET foreign_key_checks=0;

;
CREATE TABLE `comments` (
  `id` integer NOT NULL auto_increment,
  `job_id` integer NULL,
  `group_id` integer NULL,
  `text` text NOT NULL,
  `user_id` integer NOT NULL,
  `hidden` enum('0','1') NOT NULL DEFAULT '0',
  `t_created` timestamp NOT NULL,
  `t_updated` timestamp NOT NULL,
  INDEX `comments_idx_group_id` (`group_id`),
  INDEX `comments_idx_job_id` (`job_id`),
  INDEX `comments_idx_user_id` (`user_id`),
  PRIMARY KEY (`id`),
  CONSTRAINT `comments_fk_group_id` FOREIGN KEY (`group_id`) REFERENCES `job_groups` (`id`) ON DELETE CASCADE ON UPDATE CASCADE,
  CONSTRAINT `comments_fk_job_id` FOREIGN KEY (`job_id`) REFERENCES `jobs` (`id`) ON DELETE CASCADE ON UPDATE CASCADE,
  CONSTRAINT `comments_fk_user_id` FOREIGN KEY (`user_id`) REFERENCES `users` (`id`)
) ENGINE=InnoDB;

;
SET foreign_key_checks=1;

;

COMMIT;

