-- Convert schema '/home/openQA/script/../dbicdh/_source/deploy/24/001-auto.yml' to '/home/openQA/script/../dbicdh/_source/deploy/25/001-auto.yml':;

;
BEGIN;

;
CREATE TABLE "job_locks" (
  "name" text NOT NULL,
  "owner" integer NOT NULL,
  "locked_by" integer,
  PRIMARY KEY ("name", "owner")
);
CREATE INDEX "job_locks_idx_locked_by" on "job_locks" ("locked_by");
CREATE INDEX "job_locks_idx_owner" on "job_locks" ("owner");

;
ALTER TABLE "job_locks" ADD CONSTRAINT "job_locks_fk_locked_by" FOREIGN KEY ("locked_by")
  REFERENCES "jobs" ("id") ON DELETE CASCADE ON UPDATE CASCADE DEFERRABLE;

;
ALTER TABLE "job_locks" ADD CONSTRAINT "job_locks_fk_owner" FOREIGN KEY ("owner")
  REFERENCES "jobs" ("id") ON DELETE CASCADE ON UPDATE CASCADE DEFERRABLE;

;

COMMIT;

