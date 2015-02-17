-- 
-- Created by SQL::Translator::Producer::MySQL
-- Created on Wed Feb 18 09:44:26 2015
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
  `t_created` timestamp NOT NULL,
  `t_updated` timestamp NOT NULL,
  PRIMARY KEY (`id`),
  UNIQUE `assets_type_name` (`type`, `name`)
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
  `prio` integer NOT NULL,
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
-- Table: `workers`
--
CREATE TABLE `workers` (
  `id` integer NOT NULL auto_increment,
  `host` text NOT NULL,
  `instance` integer NOT NULL,
  `backend` text NOT NULL,
  `t_created` timestamp NOT NULL,
  `t_updated` timestamp NOT NULL,
  PRIMARY KEY (`id`),
  UNIQUE `workers_host_instance` (`host`, `instance`)
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
-- Table: `jobs`
--
CREATE TABLE `jobs` (
  `id` integer NOT NULL auto_increment,
  `slug` text NULL,
  `state` varchar(255) NOT NULL DEFAULT 'scheduled',
  `priority` integer NOT NULL DEFAULT 50,
  `result` varchar(255) NOT NULL DEFAULT 'none',
  `worker_id` integer NOT NULL DEFAULT 0,
  `test` text NOT NULL,
  `clone_id` integer NULL,
  `retry_avbl` integer NOT NULL DEFAULT 3,
  `backend_info` text NULL,
  `t_started` timestamp NULL,
  `t_finished` timestamp NULL,
  `t_created` timestamp NOT NULL,
  `t_updated` timestamp NOT NULL,
  INDEX `jobs_idx_clone_id` (`clone_id`),
  INDEX `jobs_idx_worker_id` (`worker_id`),
  INDEX `idx_jobs_state` (`state`),
  INDEX `idx_jobs_result` (`result`),
  PRIMARY KEY (`id`),
  UNIQUE `jobs_slug` (`slug`),
  CONSTRAINT `jobs_fk_clone_id` FOREIGN KEY (`clone_id`) REFERENCES `jobs` (`id`) ON DELETE SET NULL,
  CONSTRAINT `jobs_fk_worker_id` FOREIGN KEY (`worker_id`) REFERENCES `workers` (`id`) ON DELETE CASCADE ON UPDATE CASCADE
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
-- Table: `job_templates`
--
CREATE TABLE `job_templates` (
  `id` integer NOT NULL auto_increment,
  `product_id` integer NOT NULL,
  `machine_id` integer NOT NULL,
  `test_suite_id` integer NOT NULL,
  `t_created` timestamp NOT NULL,
  `t_updated` timestamp NOT NULL,
  INDEX `job_templates_idx_machine_id` (`machine_id`),
  INDEX `job_templates_idx_product_id` (`product_id`),
  INDEX `job_templates_idx_test_suite_id` (`test_suite_id`),
  PRIMARY KEY (`id`),
  UNIQUE `job_templates_product_id_machine_id_test_suite_id` (`product_id`, `machine_id`, `test_suite_id`),
  CONSTRAINT `job_templates_fk_machine_id` FOREIGN KEY (`machine_id`) REFERENCES `machines` (`id`) ON DELETE CASCADE ON UPDATE CASCADE,
  CONSTRAINT `job_templates_fk_product_id` FOREIGN KEY (`product_id`) REFERENCES `products` (`id`) ON DELETE CASCADE ON UPDATE CASCADE,
  CONSTRAINT `job_templates_fk_test_suite_id` FOREIGN KEY (`test_suite_id`) REFERENCES `test_suites` (`id`) ON DELETE CASCADE ON UPDATE CASCADE
) ENGINE=InnoDB;
--
-- Table: `jobs_assets`
--
CREATE TABLE `jobs_assets` (
  `job_id` integer NOT NULL,
  `asset_id` integer NOT NULL,
  `t_created` timestamp NOT NULL,
  `t_updated` timestamp NOT NULL,
  INDEX `jobs_assets_idx_asset_id` (`asset_id`),
  INDEX `jobs_assets_idx_job_id` (`job_id`),
  UNIQUE `jobs_assets_job_id_asset_id` (`job_id`, `asset_id`),
  CONSTRAINT `jobs_assets_fk_asset_id` FOREIGN KEY (`asset_id`) REFERENCES `assets` (`id`) ON DELETE CASCADE ON UPDATE CASCADE,
  CONSTRAINT `jobs_assets_fk_job_id` FOREIGN KEY (`job_id`) REFERENCES `jobs` (`id`) ON DELETE CASCADE ON UPDATE CASCADE
) ENGINE=InnoDB;
SET foreign_key_checks=1;
