-- Convert schema '/space/prod/openQA/script/../dbicdh/_source/deploy/31/001-auto.yml' to '/space/prod/openQA/script/../dbicdh/_source/deploy/32/001-auto.yml':;

;
BEGIN;

;
CREATE TABLE "comments" (
  "id" serial NOT NULL,
  "job_id" integer,
  "group_id" integer,
  "text" text NOT NULL,
  "user_id" integer NOT NULL,
  "hidden" boolean DEFAULT '0' NOT NULL,
  "t_created" timestamp NOT NULL,
  "t_updated" timestamp NOT NULL,
  PRIMARY KEY ("id")
);
CREATE INDEX "comments_idx_group_id" on "comments" ("group_id");
CREATE INDEX "comments_idx_job_id" on "comments" ("job_id");
CREATE INDEX "comments_idx_user_id" on "comments" ("user_id");

;
ALTER TABLE "comments" ADD CONSTRAINT "comments_fk_group_id" FOREIGN KEY ("group_id")
  REFERENCES "job_groups" ("id") ON DELETE CASCADE ON UPDATE CASCADE DEFERRABLE;

;
ALTER TABLE "comments" ADD CONSTRAINT "comments_fk_job_id" FOREIGN KEY ("job_id")
  REFERENCES "jobs" ("id") ON DELETE CASCADE ON UPDATE CASCADE DEFERRABLE;

;
ALTER TABLE "comments" ADD CONSTRAINT "comments_fk_user_id" FOREIGN KEY ("user_id")
  REFERENCES "users" ("id") DEFERRABLE;

;

COMMIT;

