-- Convert schema '/home/openQA/openQA/script/../dbicdh/_source/deploy/35/001-auto.yml' to '/home/openQA/openQA/script/../dbicdh/_source/deploy/36/001-auto.yml':;

;
BEGIN;

;
SET foreign_key_checks=0;

;
CREATE TABLE `audit_events` (
  `id` integer NOT NULL auto_increment,
  `user_id` integer NULL,
  `connection_id` text NULL,
  `event` text NOT NULL,
  `event_data` text NULL,
  `t_created` timestamp NOT NULL,
  `t_updated` timestamp NOT NULL,
  INDEX `audit_events_idx_user_id` (`user_id`),
  PRIMARY KEY (`id`),
  CONSTRAINT `audit_events_fk_user_id` FOREIGN KEY (`user_id`) REFERENCES `users` (`id`)
) ENGINE=InnoDB;

;
SET foreign_key_checks=1;

;

COMMIT;

