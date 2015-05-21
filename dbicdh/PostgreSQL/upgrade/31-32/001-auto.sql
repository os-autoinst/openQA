-- Convert schema '/space/prod/openQA/script/../dbicdh/_source/deploy/31/001-auto.yml' to '/space/prod/openQA/script/../dbicdh/_source/deploy/32/001-auto.yml':;

;
BEGIN;

;
CREATE TABLE "job_comments" (
  "id" serial NOT NULL,
  "job_id" integer NOT NULL,
  "text" text NOT NULL,
  "user_id" integer NOT NULL,
  "t_created" timestamp NOT NULL,
  "t_updated" timestamp NOT NULL,
  PRIMARY KEY ("id")
);
CREATE INDEX "job_comments_idx_user_id" on "job_comments" ("user_id");
CREATE INDEX "job_comments_idx_job_id" on "job_comments" ("job_id");

;
ALTER TABLE "job_comments" ADD CONSTRAINT "job_comments_fk_user_id" FOREIGN KEY ("user_id")
  REFERENCES "users" ("id") DEFERRABLE;

;
ALTER TABLE "job_comments" ADD CONSTRAINT "job_comments_fk_job_id" FOREIGN KEY ("job_id")
  REFERENCES "jobs" ("id") ON DELETE CASCADE ON UPDATE CASCADE DEFERRABLE;

;

COMMIT;

