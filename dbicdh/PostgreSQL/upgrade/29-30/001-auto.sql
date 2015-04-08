-- Convert schema '/space/prod/openQA/script/../dbicdh/_source/deploy/29/001-auto.yml' to '/space/prod/openQA/script/../dbicdh/_source/deploy/30/001-auto.yml':;

;
BEGIN;

;
CREATE TABLE "gru_tasks" (
  "id" serial NOT NULL,
  "taskname" text NOT NULL,
  "args" text NOT NULL,
  "run_at" timestamp NOT NULL,
  "priority" integer NOT NULL,
  "t_created" timestamp NOT NULL,
  "t_updated" timestamp NOT NULL,
  PRIMARY KEY ("id")
);

;
ALTER TABLE assets ADD COLUMN size bigint;

;
ALTER TABLE job_groups ADD COLUMN size_limit_gb integer DEFAULT 100 NOT NULL;

;
ALTER TABLE job_groups ADD COLUMN keep_logs_in_days integer DEFAULT 30 NOT NULL;

;
ALTER TABLE jobs_assets ADD COLUMN created_by boolean DEFAULT '0' NOT NULL;

;

COMMIT;

