-- Convert schema '/home/martchus/repos/openQA/script/../dbicdh/_source/deploy/46/001-auto.yml' to '/home/martchus/repos/openQA/script/../dbicdh/_source/deploy/47/001-auto.yml':;

;
BEGIN;

;
CREATE TABLE "jobgroupsubscriptions" (
  "group_id" integer NOT NULL,
  "user_id" integer NOT NULL,
  "flags" integer DEFAULT 0,
  "t_created" timestamp NOT NULL,
  "t_updated" timestamp NOT NULL,
  PRIMARY KEY ("group_id", "user_id")
);
CREATE INDEX "jobgroupsubscriptions_idx_group_id" on "jobgroupsubscriptions" ("group_id");
CREATE INDEX "jobgroupsubscriptions_idx_user_id" on "jobgroupsubscriptions" ("user_id");

;
ALTER TABLE "jobgroupsubscriptions" ADD CONSTRAINT "jobgroupsubscriptions_fk_group_id" FOREIGN KEY ("group_id")
  REFERENCES "job_groups" ("id") ON DELETE CASCADE ON UPDATE CASCADE DEFERRABLE;

;
ALTER TABLE "jobgroupsubscriptions" ADD CONSTRAINT "jobgroupsubscriptions_fk_user_id" FOREIGN KEY ("user_id")
  REFERENCES "users" ("id") ON DELETE CASCADE ON UPDATE CASCADE DEFERRABLE;

;

COMMIT;

