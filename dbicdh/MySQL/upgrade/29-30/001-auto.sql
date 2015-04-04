-- Convert schema '/home/coolo/prod/openQA/script/../dbicdh/_source/deploy/29/001-auto.yml' to '/home/coolo/prod/openQA/script/../dbicdh/_source/deploy/30/001-auto.yml':;

;
BEGIN;

;
SET foreign_key_checks=0;

;
CREATE TABLE `gru_tasks` (
  `id` integer NOT NULL auto_increment,
  `taskname` text NOT NULL,
  `args` text NOT NULL,
  `run_at` datetime NOT NULL,
  `priority` integer NOT NULL,
  `t_created` timestamp NOT NULL,
  `t_updated` timestamp NOT NULL,
  PRIMARY KEY (`id`)
);

;
SET foreign_key_checks=1;

;

COMMIT;

