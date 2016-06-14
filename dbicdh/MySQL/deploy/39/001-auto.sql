-- 
-- Created by SQL::Translator::Producer::MySQL
-- Created on Tue Jun 14 21:06:59 2016
-- 
;
SET foreign_key_checks=0;
--
-- Table: `assets`
--
CREATE TABLE `assets` (
  `id` integer NOT NULL auto_increment,
  `type` text NOT NULL,
  `name` text NOT NULL,
  `size` bigint NULL,
  `t_created` timestamp NOT NULL,
  `t_updated` timestamp NOT NULL,
  PRIMARY KEY (`id`),
  UNIQUE `assets_type_name` (`type`, `name`)
) ENGINE=InnoDB;
--
-- Table: `gru_tasks`
--
CREATE TABLE `gru_tasks` (
  `id` integer NOT NULL auto_increment,
  `taskname` text NOT NULL,
  `args` text NOT NULL,
  `run_at` datetime NOT NULL,
  `priority` integer NOT NULL,
  `t_created` timestamp NOT NULL,
  `t_updated` timestamp NOT NULL,
  PRIMARY KEY (`id`)
) ENGINE=InnoDB;
--
-- Table: `job_groups`
--
CREATE TABLE `job_groups` (
  `id` integer NOT NULL auto_increment,
  `name` text NOT NULL,
  `size_limit_gb` integer NOT NULL DEFAULT 100,
  `keep_logs_in_days` integer NOT NULL DEFAULT 30,
  `t_created` timestamp NOT NULL,
  `t_updated` timestamp NOT NULL,
  PRIMARY KEY (`id`),
  UNIQUE `job_groups_name` (`name`)
) ENGINE=InnoDB;
--
-- Table: `job_modules`
--
CREATE TABLE `job_modules` (
  `id` integer NOT NULL auto_increment,
  `job_id` integer NOT NULL,
  `name` text NOT NULL,
  `script` text NOT NULL,
  `category` text NOT NULL,
  `soft_failure` integer NOT NULL DEFAULT 0,
  `milestone` integer NOT NULL DEFAULT 0,
  `important` integer NOT NULL DEFAULT 0,
  `fatal` integer NOT NULL DEFAULT 0,
  `result` varchar(255) NOT NULL DEFAULT 'none',
  `t_created` timestamp NOT NULL,
  `t_updated` timestamp NOT NULL,
  INDEX `job_modules_idx_job_id` (`job_id`),
  INDEX `idx_job_modules_result` (`result`),
  PRIMARY KEY (`id`),
  CONSTRAINT `job_modules_fk_job_id` FOREIGN KEY (`job_id`) REFERENCES `jobs` (`id`) ON DELETE CASCADE ON UPDATE CASCADE
) ENGINE=InnoDB;
--
-- Table: `job_settings`
--
CREATE TABLE `job_settings` (
  `id` integer NOT NULL auto_increment,
  `key` text NOT NULL,
  `value` text NOT NULL,
  `job_id` integer NOT NULL,
  `t_created` timestamp NOT NULL,
  `t_updated` timestamp NOT NULL,
  INDEX `job_settings_idx_job_id` (`job_id`),
  INDEX `idx_value_settings` (`key`, `value`),
  INDEX `idx_job_id_value_settings` (`job_id`, `key`, `value`),
  PRIMARY KEY (`id`),
  CONSTRAINT `job_settings_fk_job_id` FOREIGN KEY (`job_id`) REFERENCES `jobs` (`id`) ON DELETE CASCADE ON UPDATE CASCADE
) ENGINE=InnoDB;
--
-- Table: `machine_settings`
--
CREATE TABLE `machine_settings` (
  `id` integer NOT NULL auto_increment,
  `machine_id` integer NOT NULL,
  `key` text NOT NULL,
  `value` text NOT NULL,
  `t_created` timestamp NOT NULL,
  `t_updated` timestamp NOT NULL,
  INDEX `machine_settings_idx_machine_id` (`machine_id`),
  PRIMARY KEY (`id`),
  UNIQUE `machine_settings_machine_id_key` (`machine_id`, `key`),
  CONSTRAINT `machine_settings_fk_machine_id` FOREIGN KEY (`machine_id`) REFERENCES `machines` (`id`) ON DELETE CASCADE ON UPDATE CASCADE
) ENGINE=InnoDB;
--
-- Table: `machines`
--
CREATE TABLE `machines` (
  `id` integer NOT NULL auto_increment,
  `name` text NOT NULL,
  `backend` text NOT NULL,
  `variables` text NOT NULL,
  `t_created` timestamp NOT NULL,
  `t_updated` timestamp NOT NULL,
  PRIMARY KEY (`id`),
  UNIQUE `machines_name` (`name`)
) ENGINE=InnoDB;
--
-- Table: `needle_dirs`
--
CREATE TABLE `needle_dirs` (
  `id` integer NOT NULL auto_increment,
  `path` text NOT NULL,
  `name` text NOT NULL,
  PRIMARY KEY (`id`),
  UNIQUE `needle_dirs_path` (`path`)
) ENGINE=InnoDB;
--
-- Table: `product_settings`
--
CREATE TABLE `product_settings` (
  `id` integer NOT NULL auto_increment,
  `product_id` integer NOT NULL,
  `key` text NOT NULL,
  `value` text NOT NULL,
  `t_created` timestamp NOT NULL,
  `t_updated` timestamp NOT NULL,
  INDEX `product_settings_idx_product_id` (`product_id`),
  PRIMARY KEY (`id`),
  UNIQUE `product_settings_product_id_key` (`product_id`, `key`),
  CONSTRAINT `product_settings_fk_product_id` FOREIGN KEY (`product_id`) REFERENCES `products` (`id`) ON DELETE CASCADE ON UPDATE CASCADE
) ENGINE=InnoDB;
--
-- Table: `products`
--
CREATE TABLE `products` (
  `id` integer NOT NULL auto_increment,
  `name` text NOT NULL,
  `distri` text NOT NULL,
  `version` text NOT NULL DEFAULT '',
  `arch` text NOT NULL,
  `flavor` text NOT NULL,
  `variables` text NOT NULL,
  `t_created` timestamp NOT NULL,
  `t_updated` timestamp NOT NULL,
  PRIMARY KEY (`id`),
  UNIQUE `products_distri_version_arch_flavor` (`distri`, `version`, `arch`, `flavor`)
) ENGINE=InnoDB;
--
-- Table: `secrets`
--
CREATE TABLE `secrets` (
  `id` integer NOT NULL auto_increment,
  `secret` text NOT NULL,
  `t_created` timestamp NOT NULL,
  `t_updated` timestamp NOT NULL,
  PRIMARY KEY (`id`),
  UNIQUE `secrets_secret` (`secret`)
);
--
-- Table: `test_suite_settings`
--
CREATE TABLE `test_suite_settings` (
  `id` integer NOT NULL auto_increment,
  `test_suite_id` integer NOT NULL,
  `key` text NOT NULL,
  `value` text NOT NULL,
  `t_created` timestamp NOT NULL,
  `t_updated` timestamp NOT NULL,
  INDEX `test_suite_settings_idx_test_suite_id` (`test_suite_id`),
  PRIMARY KEY (`id`),
  UNIQUE `test_suite_settings_test_suite_id_key` (`test_suite_id`, `key`),
  CONSTRAINT `test_suite_settings_fk_test_suite_id` FOREIGN KEY (`test_suite_id`) REFERENCES `test_suites` (`id`) ON DELETE CASCADE ON UPDATE CASCADE
) ENGINE=InnoDB;
--
-- Table: `test_suites`
--
CREATE TABLE `test_suites` (
  `id` integer NOT NULL auto_increment,
  `name` text NOT NULL,
  `variables` text NOT NULL,
  `t_created` timestamp NOT NULL,
  `t_updated` timestamp NOT NULL,
  PRIMARY KEY (`id`),
  UNIQUE `test_suites_name` (`name`)
) ENGINE=InnoDB;
--
-- Table: `users`
--
CREATE TABLE `users` (
  `id` integer NOT NULL auto_increment,
  `username` text NOT NULL,
  `email` text NULL,
  `fullname` text NULL,
  `nickname` text NULL,
  `is_operator` integer NOT NULL DEFAULT 0,
  `is_admin` integer NOT NULL DEFAULT 0,
  `t_created` timestamp NOT NULL,
  `t_updated` timestamp NOT NULL,
  PRIMARY KEY (`id`),
  UNIQUE `users_username` (`username`)
) ENGINE=InnoDB;
--
-- Table: `worker_properties`
--
CREATE TABLE `worker_properties` (
  `id` integer NOT NULL auto_increment,
  `key` text NOT NULL,
  `value` text NOT NULL,
  `worker_id` integer NOT NULL,
  `t_created` timestamp NOT NULL,
  `t_updated` timestamp NOT NULL,
  INDEX `worker_properties_idx_worker_id` (`worker_id`),
  PRIMARY KEY (`id`),
  CONSTRAINT `worker_properties_fk_worker_id` FOREIGN KEY (`worker_id`) REFERENCES `workers` (`id`) ON DELETE CASCADE ON UPDATE CASCADE
) ENGINE=InnoDB;
--
-- Table: `api_keys`
--
CREATE TABLE `api_keys` (
  `id` integer NOT NULL auto_increment,
  `key` text NOT NULL,
  `secret` text NOT NULL,
  `user_id` integer NOT NULL,
  `t_expiration` timestamp NULL,
  `t_created` timestamp NOT NULL,
  `t_updated` timestamp NOT NULL,
  INDEX `api_keys_idx_user_id` (`user_id`),
  PRIMARY KEY (`id`),
  UNIQUE `api_keys_key` (`key`),
  CONSTRAINT `api_keys_fk_user_id` FOREIGN KEY (`user_id`) REFERENCES `users` (`id`) ON DELETE CASCADE ON UPDATE CASCADE
) ENGINE=InnoDB;
--
-- Table: `audit_events`
--
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
--
-- Table: `comments`
--
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
--
-- Table: `jobs`
--
CREATE TABLE `jobs` (
  `id` integer NOT NULL auto_increment,
  `slug` text NULL,
  `result_dir` text NULL,
  `state` varchar(255) NOT NULL DEFAULT 'scheduled',
  `priority` integer NOT NULL DEFAULT 50,
  `result` varchar(255) NOT NULL DEFAULT 'none',
  `clone_id` integer NULL,
  `retry_avbl` integer NOT NULL DEFAULT 3,
  `backend` varchar(255) NULL,
  `backend_info` text NULL,
  `TEST` text NULL,
  `DISTRI` text NULL,
  `VERSION` text NULL,
  `FLAVOR` text NULL,
  `ARCH` text NULL,
  `BUILD` text NULL,
  `MACHINE` text NULL,
  `group_id` integer NULL,
  `t_started` timestamp NULL,
  `t_finished` timestamp NULL,
  `t_created` timestamp NOT NULL,
  `t_updated` timestamp NOT NULL,
  INDEX `jobs_idx_clone_id` (`clone_id`),
  INDEX `jobs_idx_group_id` (`group_id`),
  INDEX `idx_jobs_state` (`state`),
  INDEX `idx_jobs_result` (`result`),
  INDEX `idx_jobs_build_group` (`BUILD`, `group_id`),
  INDEX `idx_jobs_scenario` (`VERSION`, `DISTRI`, `FLAVOR`, `TEST`, `MACHINE`, `ARCH`),
  PRIMARY KEY (`id`),
  UNIQUE `jobs_slug` (`slug`),
  CONSTRAINT `jobs_fk_clone_id` FOREIGN KEY (`clone_id`) REFERENCES `jobs` (`id`) ON DELETE SET NULL,
  CONSTRAINT `jobs_fk_group_id` FOREIGN KEY (`group_id`) REFERENCES `job_groups` (`id`) ON DELETE SET NULL ON UPDATE CASCADE
) ENGINE=InnoDB;
--
-- Table: `job_dependencies`
--
CREATE TABLE `job_dependencies` (
  `child_job_id` integer NOT NULL,
  `parent_job_id` integer NOT NULL,
  `dependency` integer NOT NULL,
  INDEX `job_dependencies_idx_child_job_id` (`child_job_id`),
  INDEX `job_dependencies_idx_parent_job_id` (`parent_job_id`),
  INDEX `idx_job_dependencies_dependency` (`dependency`),
  PRIMARY KEY (`child_job_id`, `parent_job_id`, `dependency`),
  CONSTRAINT `job_dependencies_fk_child_job_id` FOREIGN KEY (`child_job_id`) REFERENCES `jobs` (`id`) ON DELETE CASCADE ON UPDATE CASCADE,
  CONSTRAINT `job_dependencies_fk_parent_job_id` FOREIGN KEY (`parent_job_id`) REFERENCES `jobs` (`id`) ON DELETE CASCADE ON UPDATE CASCADE
) ENGINE=InnoDB;
--
-- Table: `job_locks`
--
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
--
-- Table: `job_networks`
--
CREATE TABLE `job_networks` (
  `name` text NOT NULL,
  `job_id` integer NOT NULL,
  `vlan` integer NOT NULL,
  INDEX `job_networks_idx_job_id` (`job_id`),
  PRIMARY KEY (`name`, `job_id`),
  CONSTRAINT `job_networks_fk_job_id` FOREIGN KEY (`job_id`) REFERENCES `jobs` (`id`) ON DELETE CASCADE ON UPDATE CASCADE
) ENGINE=InnoDB;
--
-- Table: `needles`
--
CREATE TABLE `needles` (
  `id` integer NOT NULL auto_increment,
  `dir_id` integer NOT NULL,
  `filename` text NOT NULL,
  `first_seen_module_id` integer NOT NULL,
  `last_seen_module_id` integer NOT NULL,
  `last_matched_module_id` integer NULL,
  `file_present` enum('0','1') NOT NULL DEFAULT '1',
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
--
-- Table: `workers`
--
CREATE TABLE `workers` (
  `id` integer NOT NULL auto_increment,
  `host` text NOT NULL,
  `instance` integer NOT NULL,
  `job_id` integer NULL,
  `t_created` timestamp NOT NULL,
  `t_updated` timestamp NOT NULL,
  INDEX `workers_idx_job_id` (`job_id`),
  PRIMARY KEY (`id`),
  UNIQUE `workers_host_instance` (`host`, `instance`),
  UNIQUE `workers_job_id` (`job_id`),
  CONSTRAINT `workers_fk_job_id` FOREIGN KEY (`job_id`) REFERENCES `jobs` (`id`) ON DELETE CASCADE
) ENGINE=InnoDB;
--
-- Table: `gru_dependencies`
--
CREATE TABLE `gru_dependencies` (
  `job_id` integer NOT NULL,
  `gru_task_id` integer NOT NULL,
  INDEX `gru_dependencies_idx_gru_task_id` (`gru_task_id`),
  INDEX `gru_dependencies_idx_job_id` (`job_id`),
  PRIMARY KEY (`job_id`, `gru_task_id`),
  CONSTRAINT `gru_dependencies_fk_gru_task_id` FOREIGN KEY (`gru_task_id`) REFERENCES `gru_tasks` (`id`) ON DELETE CASCADE ON UPDATE CASCADE,
  CONSTRAINT `gru_dependencies_fk_job_id` FOREIGN KEY (`job_id`) REFERENCES `jobs` (`id`) ON DELETE CASCADE ON UPDATE CASCADE
) ENGINE=InnoDB;
--
-- Table: `job_module_needles`
--
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
--
-- Table: `jobs_assets`
--
CREATE TABLE `jobs_assets` (
  `job_id` integer NOT NULL,
  `asset_id` integer NOT NULL,
  `created_by` enum('0','1') NOT NULL DEFAULT '0',
  `t_created` timestamp NOT NULL,
  `t_updated` timestamp NOT NULL,
  INDEX `jobs_assets_idx_asset_id` (`asset_id`),
  INDEX `jobs_assets_idx_job_id` (`job_id`),
  UNIQUE `jobs_assets_job_id_asset_id` (`job_id`, `asset_id`),
  CONSTRAINT `jobs_assets_fk_asset_id` FOREIGN KEY (`asset_id`) REFERENCES `assets` (`id`) ON DELETE CASCADE ON UPDATE CASCADE,
  CONSTRAINT `jobs_assets_fk_job_id` FOREIGN KEY (`job_id`) REFERENCES `jobs` (`id`) ON DELETE CASCADE ON UPDATE CASCADE
) ENGINE=InnoDB;
--
-- Table: `job_templates`
--
CREATE TABLE `job_templates` (
  `id` integer NOT NULL auto_increment,
  `product_id` integer NOT NULL,
  `machine_id` integer NOT NULL,
  `test_suite_id` integer NOT NULL,
  `prio` integer NOT NULL,
  `group_id` integer NOT NULL,
  `t_created` timestamp NOT NULL,
  `t_updated` timestamp NOT NULL,
  INDEX `job_templates_idx_group_id` (`group_id`),
  INDEX `job_templates_idx_machine_id` (`machine_id`),
  INDEX `job_templates_idx_product_id` (`product_id`),
  INDEX `job_templates_idx_test_suite_id` (`test_suite_id`),
  PRIMARY KEY (`id`),
  UNIQUE `job_templates_product_id_machine_id_test_suite_id` (`product_id`, `machine_id`, `test_suite_id`),
  CONSTRAINT `job_templates_fk_group_id` FOREIGN KEY (`group_id`) REFERENCES `job_groups` (`id`),
  CONSTRAINT `job_templates_fk_machine_id` FOREIGN KEY (`machine_id`) REFERENCES `machines` (`id`) ON DELETE CASCADE ON UPDATE CASCADE,
  CONSTRAINT `job_templates_fk_product_id` FOREIGN KEY (`product_id`) REFERENCES `products` (`id`) ON DELETE CASCADE ON UPDATE CASCADE,
  CONSTRAINT `job_templates_fk_test_suite_id` FOREIGN KEY (`test_suite_id`) REFERENCES `test_suites` (`id`) ON DELETE CASCADE ON UPDATE CASCADE
) ENGINE=InnoDB;
SET foreign_key_checks=1;
