-- Convert schema '/home/martchus/repos/openQA/script/../dbicdh/_source/deploy/46/001-auto.yml' to '/home/martchus/repos/openQA/script/../dbicdh/_source/deploy/47/001-auto.yml':;

;
BEGIN;

;
CREATE TABLE "job_group_parents" (
  "id" serial NOT NULL,
  "name" text NOT NULL,
  "default_size_limit_gb" integer,
  "default_keep_logs_in_days" integer,
  "default_keep_important_logs_in_days" integer,
  "default_keep_results_in_days" integer,
  "default_keep_important_results_in_days" integer,
  "default_priority" integer,
  "sort_order" integer,
  "description" text,
  "t_created" timestamp NOT NULL,
  "t_updated" timestamp NOT NULL,
  PRIMARY KEY ("id"),
  CONSTRAINT "job_group_parents_name" UNIQUE ("name")
);

;
ALTER TABLE job_groups ADD COLUMN parent_id integer;

;
ALTER TABLE job_groups ADD COLUMN keep_important_logs_in_days integer;

;
ALTER TABLE job_groups ADD COLUMN keep_results_in_days integer;

;
ALTER TABLE job_groups ADD COLUMN keep_important_results_in_days integer;

;
ALTER TABLE job_groups ADD COLUMN default_priority integer;

;
ALTER TABLE job_groups ADD COLUMN sort_order integer;

;
ALTER TABLE job_groups ADD COLUMN description text;

;
ALTER TABLE job_groups ALTER COLUMN size_limit_gb DROP NOT NULL;

;
ALTER TABLE job_groups ALTER COLUMN size_limit_gb DROP DEFAULT;

;
ALTER TABLE job_groups ALTER COLUMN keep_logs_in_days DROP NOT NULL;

;
ALTER TABLE job_groups ALTER COLUMN keep_logs_in_days DROP DEFAULT;

;
CREATE INDEX job_groups_idx_parent_id on job_groups (parent_id);

;
ALTER TABLE job_groups ADD CONSTRAINT job_groups_fk_parent_id FOREIGN KEY (parent_id)
  REFERENCES job_group_parents (id) ON DELETE SET NULL ON UPDATE CASCADE DEFERRABLE;

;

COMMIT;

