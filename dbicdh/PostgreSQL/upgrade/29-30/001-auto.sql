-- Convert schema '/home/coolo/prod/openQA/script/../dbicdh/_source/deploy/29/001-auto.yml' to '/home/coolo/prod/openQA/script/../dbicdh/_source/deploy/30/001-auto.yml':;

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

COMMIT;

