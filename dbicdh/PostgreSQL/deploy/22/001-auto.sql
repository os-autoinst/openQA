-- 
-- Created by SQL::Translator::Producer::PostgreSQL
-- Created on Mon Jan 19 13:24:28 2015
-- 
;
--
-- Table: assets.
--
CREATE TABLE "assets" (
  "id" serial NOT NULL,
  "type" text NOT NULL,
  "name" text NOT NULL,
  "t_created" timestamp NOT NULL,
  "t_updated" timestamp NOT NULL,
  PRIMARY KEY ("id"),
  CONSTRAINT "assets_type_name" UNIQUE ("type", "name")
);

;
--
-- Table: job_modules.
--
CREATE TABLE "job_modules" (
  "id" serial NOT NULL,
  "job_id" integer NOT NULL,
  "name" text NOT NULL,
  "script" text NOT NULL,
  "category" text NOT NULL,
  "result" character varying DEFAULT 'none' NOT NULL,
  "t_created" timestamp NOT NULL,
  "t_updated" timestamp NOT NULL,
  PRIMARY KEY ("id")
);
CREATE INDEX "job_modules_idx_job_id" on "job_modules" ("job_id");
CREATE INDEX "idx_job_modules_result" on "job_modules" ("result");

;
--
-- Table: job_settings.
--
CREATE TABLE "job_settings" (
  "id" serial NOT NULL,
  "key" text NOT NULL,
  "value" text NOT NULL,
  "job_id" integer NOT NULL,
  "t_created" timestamp NOT NULL,
  "t_updated" timestamp NOT NULL,
  PRIMARY KEY ("id")
);
CREATE INDEX "job_settings_idx_job_id" on "job_settings" ("job_id");

;
--
-- Table: machine_settings.
--
CREATE TABLE "machine_settings" (
  "id" serial NOT NULL,
  "machine_id" integer NOT NULL,
  "key" text NOT NULL,
  "value" text NOT NULL,
  "t_created" timestamp NOT NULL,
  "t_updated" timestamp NOT NULL,
  PRIMARY KEY ("id"),
  CONSTRAINT "machine_settings_machine_id_key" UNIQUE ("machine_id", "key")
);
CREATE INDEX "machine_settings_idx_machine_id" on "machine_settings" ("machine_id");

;
--
-- Table: machines.
--
CREATE TABLE "machines" (
  "id" serial NOT NULL,
  "name" text NOT NULL,
  "backend" text NOT NULL,
  "variables" text NOT NULL,
  "t_created" timestamp NOT NULL,
  "t_updated" timestamp NOT NULL,
  PRIMARY KEY ("id"),
  CONSTRAINT "machines_name" UNIQUE ("name")
);

;
--
-- Table: product_settings.
--
CREATE TABLE "product_settings" (
  "id" serial NOT NULL,
  "product_id" integer NOT NULL,
  "key" text NOT NULL,
  "value" text NOT NULL,
  "t_created" timestamp NOT NULL,
  "t_updated" timestamp NOT NULL,
  PRIMARY KEY ("id"),
  CONSTRAINT "product_settings_product_id_key" UNIQUE ("product_id", "key")
);
CREATE INDEX "product_settings_idx_product_id" on "product_settings" ("product_id");

;
--
-- Table: products.
--
CREATE TABLE "products" (
  "id" serial NOT NULL,
  "name" text NOT NULL,
  "distri" text NOT NULL,
  "version" text DEFAULT '' NOT NULL,
  "arch" text NOT NULL,
  "flavor" text NOT NULL,
  "variables" text NOT NULL,
  "t_created" timestamp NOT NULL,
  "t_updated" timestamp NOT NULL,
  PRIMARY KEY ("id"),
  CONSTRAINT "products_distri_version_arch_flavor" UNIQUE ("distri", "version", "arch", "flavor")
);

;
--
-- Table: secrets.
--
CREATE TABLE "secrets" (
  "id" serial NOT NULL,
  "secret" text NOT NULL,
  "t_created" timestamp NOT NULL,
  "t_updated" timestamp NOT NULL,
  PRIMARY KEY ("id"),
  CONSTRAINT "secrets_secret" UNIQUE ("secret")
);

;
--
-- Table: test_suite_settings.
--
CREATE TABLE "test_suite_settings" (
  "id" serial NOT NULL,
  "test_suite_id" integer NOT NULL,
  "key" text NOT NULL,
  "value" text NOT NULL,
  "t_created" timestamp NOT NULL,
  "t_updated" timestamp NOT NULL,
  PRIMARY KEY ("id"),
  CONSTRAINT "test_suite_settings_test_suite_id_key" UNIQUE ("test_suite_id", "key")
);
CREATE INDEX "test_suite_settings_idx_test_suite_id" on "test_suite_settings" ("test_suite_id");

;
--
-- Table: test_suites.
--
CREATE TABLE "test_suites" (
  "id" serial NOT NULL,
  "name" text NOT NULL,
  "variables" text NOT NULL,
  "prio" integer NOT NULL,
  "t_created" timestamp NOT NULL,
  "t_updated" timestamp NOT NULL,
  PRIMARY KEY ("id"),
  CONSTRAINT "test_suites_name" UNIQUE ("name")
);

;
--
-- Table: users.
--
CREATE TABLE "users" (
  "id" serial NOT NULL,
  "openid" text NOT NULL,
  "email" text,
  "fullname" text,
  "nickname" text,
  "is_operator" integer DEFAULT 0 NOT NULL,
  "is_admin" integer DEFAULT 0 NOT NULL,
  "t_created" timestamp NOT NULL,
  "t_updated" timestamp NOT NULL,
  PRIMARY KEY ("id"),
  CONSTRAINT "users_openid" UNIQUE ("openid")
);

;
--
-- Table: worker_properties.
--
CREATE TABLE "worker_properties" (
  "id" serial NOT NULL,
  "key" text NOT NULL,
  "value" text NOT NULL,
  "worker_id" integer NOT NULL,
  "t_created" timestamp NOT NULL,
  "t_updated" timestamp NOT NULL,
  PRIMARY KEY ("id")
);
CREATE INDEX "worker_properties_idx_worker_id" on "worker_properties" ("worker_id");

;
--
-- Table: workers.
--
CREATE TABLE "workers" (
  "id" serial NOT NULL,
  "host" text NOT NULL,
  "instance" integer NOT NULL,
  "backend" text NOT NULL,
  "t_created" timestamp NOT NULL,
  "t_updated" timestamp NOT NULL,
  PRIMARY KEY ("id"),
  CONSTRAINT "workers_host_instance" UNIQUE ("host", "instance")
);

;
--
-- Table: api_keys.
--
CREATE TABLE "api_keys" (
  "id" serial NOT NULL,
  "key" text NOT NULL,
  "secret" text NOT NULL,
  "user_id" integer NOT NULL,
  "t_expiration" timestamp,
  "t_created" timestamp NOT NULL,
  "t_updated" timestamp NOT NULL,
  PRIMARY KEY ("id"),
  CONSTRAINT "api_keys_key" UNIQUE ("key")
);
CREATE INDEX "api_keys_idx_user_id" on "api_keys" ("user_id");

;
--
-- Table: jobs.
--
CREATE TABLE "jobs" (
  "id" serial NOT NULL,
  "slug" text,
  "state" character varying DEFAULT 'scheduled' NOT NULL,
  "priority" integer DEFAULT 50 NOT NULL,
  "result" character varying DEFAULT 'none' NOT NULL,
  "worker_id" integer DEFAULT 0 NOT NULL,
  "test" text NOT NULL,
  "test_branch" text,
  "clone_id" integer,
  "retry_avbl" integer DEFAULT 3 NOT NULL,
  "t_started" timestamp,
  "t_finished" timestamp,
  "t_created" timestamp NOT NULL,
  "t_updated" timestamp NOT NULL,
  PRIMARY KEY ("id"),
  CONSTRAINT "jobs_slug" UNIQUE ("slug")
);
CREATE INDEX "jobs_idx_clone_id" on "jobs" ("clone_id");
CREATE INDEX "jobs_idx_worker_id" on "jobs" ("worker_id");
CREATE INDEX "idx_jobs_state" on "jobs" ("state");
CREATE INDEX "idx_jobs_result" on "jobs" ("result");

;
--
-- Table: job_dependencies.
--
CREATE TABLE "job_dependencies" (
  "child_job_id" integer NOT NULL,
  "parent_job_id" integer NOT NULL,
  "dependency" integer NOT NULL,
  PRIMARY KEY ("child_job_id", "parent_job_id", "dependency")
);
CREATE INDEX "job_dependencies_idx_child_job_id" on "job_dependencies" ("child_job_id");
CREATE INDEX "job_dependencies_idx_parent_job_id" on "job_dependencies" ("parent_job_id");
CREATE INDEX "idx_job_dependencies_dependency" on "job_dependencies" ("dependency");

;
--
-- Table: job_templates.
--
CREATE TABLE "job_templates" (
  "id" serial NOT NULL,
  "product_id" integer NOT NULL,
  "machine_id" integer NOT NULL,
  "test_suite_id" integer NOT NULL,
  "t_created" timestamp NOT NULL,
  "t_updated" timestamp NOT NULL,
  PRIMARY KEY ("id"),
  CONSTRAINT "job_templates_product_id_machine_id_test_suite_id" UNIQUE ("product_id", "machine_id", "test_suite_id")
);
CREATE INDEX "job_templates_idx_machine_id" on "job_templates" ("machine_id");
CREATE INDEX "job_templates_idx_product_id" on "job_templates" ("product_id");
CREATE INDEX "job_templates_idx_test_suite_id" on "job_templates" ("test_suite_id");

;
--
-- Table: jobs_assets.
--
CREATE TABLE "jobs_assets" (
  "job_id" integer NOT NULL,
  "asset_id" integer NOT NULL,
  "t_created" timestamp NOT NULL,
  "t_updated" timestamp NOT NULL,
  CONSTRAINT "jobs_assets_job_id_asset_id" UNIQUE ("job_id", "asset_id")
);
CREATE INDEX "jobs_assets_idx_asset_id" on "jobs_assets" ("asset_id");
CREATE INDEX "jobs_assets_idx_job_id" on "jobs_assets" ("job_id");

;
--
-- Foreign Key Definitions
--

;
ALTER TABLE "job_modules" ADD CONSTRAINT "job_modules_fk_job_id" FOREIGN KEY ("job_id")
  REFERENCES "jobs" ("id") ON DELETE CASCADE ON UPDATE CASCADE DEFERRABLE;

;
ALTER TABLE "job_settings" ADD CONSTRAINT "job_settings_fk_job_id" FOREIGN KEY ("job_id")
  REFERENCES "jobs" ("id") ON DELETE CASCADE ON UPDATE CASCADE DEFERRABLE;

;
ALTER TABLE "machine_settings" ADD CONSTRAINT "machine_settings_fk_machine_id" FOREIGN KEY ("machine_id")
  REFERENCES "machines" ("id") ON DELETE CASCADE ON UPDATE CASCADE DEFERRABLE;

;
ALTER TABLE "product_settings" ADD CONSTRAINT "product_settings_fk_product_id" FOREIGN KEY ("product_id")
  REFERENCES "products" ("id") ON DELETE CASCADE ON UPDATE CASCADE DEFERRABLE;

;
ALTER TABLE "test_suite_settings" ADD CONSTRAINT "test_suite_settings_fk_test_suite_id" FOREIGN KEY ("test_suite_id")
  REFERENCES "test_suites" ("id") ON DELETE CASCADE ON UPDATE CASCADE DEFERRABLE;

;
ALTER TABLE "worker_properties" ADD CONSTRAINT "worker_properties_fk_worker_id" FOREIGN KEY ("worker_id")
  REFERENCES "workers" ("id") ON DELETE CASCADE ON UPDATE CASCADE DEFERRABLE;

;
ALTER TABLE "api_keys" ADD CONSTRAINT "api_keys_fk_user_id" FOREIGN KEY ("user_id")
  REFERENCES "users" ("id") ON DELETE CASCADE ON UPDATE CASCADE DEFERRABLE;

;
ALTER TABLE "jobs" ADD CONSTRAINT "jobs_fk_clone_id" FOREIGN KEY ("clone_id")
  REFERENCES "jobs" ("id") ON DELETE SET NULL DEFERRABLE;

;
ALTER TABLE "jobs" ADD CONSTRAINT "jobs_fk_worker_id" FOREIGN KEY ("worker_id")
  REFERENCES "workers" ("id") ON DELETE CASCADE ON UPDATE CASCADE DEFERRABLE;

;
ALTER TABLE "job_dependencies" ADD CONSTRAINT "job_dependencies_fk_child_job_id" FOREIGN KEY ("child_job_id")
  REFERENCES "jobs" ("id") ON DELETE CASCADE ON UPDATE CASCADE DEFERRABLE;

;
ALTER TABLE "job_dependencies" ADD CONSTRAINT "job_dependencies_fk_parent_job_id" FOREIGN KEY ("parent_job_id")
  REFERENCES "jobs" ("id") ON DELETE CASCADE ON UPDATE CASCADE DEFERRABLE;

;
ALTER TABLE "job_templates" ADD CONSTRAINT "job_templates_fk_machine_id" FOREIGN KEY ("machine_id")
  REFERENCES "machines" ("id") ON DELETE CASCADE ON UPDATE CASCADE DEFERRABLE;

;
ALTER TABLE "job_templates" ADD CONSTRAINT "job_templates_fk_product_id" FOREIGN KEY ("product_id")
  REFERENCES "products" ("id") ON DELETE CASCADE ON UPDATE CASCADE DEFERRABLE;

;
ALTER TABLE "job_templates" ADD CONSTRAINT "job_templates_fk_test_suite_id" FOREIGN KEY ("test_suite_id")
  REFERENCES "test_suites" ("id") ON DELETE CASCADE ON UPDATE CASCADE DEFERRABLE;

;
ALTER TABLE "jobs_assets" ADD CONSTRAINT "jobs_assets_fk_asset_id" FOREIGN KEY ("asset_id")
  REFERENCES "assets" ("id") ON DELETE CASCADE ON UPDATE CASCADE DEFERRABLE;

;
ALTER TABLE "jobs_assets" ADD CONSTRAINT "jobs_assets_fk_job_id" FOREIGN KEY ("job_id")
  REFERENCES "jobs" ("id") ON DELETE CASCADE ON UPDATE CASCADE DEFERRABLE;

;
