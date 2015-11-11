-- Convert schema '/space/prod/openQA/script/../dbicdh/_source/deploy/33/001-auto.yml' to '/space/prod/openQA/script/../dbicdh/_source/deploy/34/001-auto.yml':;

;
BEGIN;

;
CREATE TABLE "job_module_needles" (
  "needle_id" integer NOT NULL,
  "job_module_id" integer NOT NULL,
  "failed" boolean DEFAULT '0' NOT NULL,
  CONSTRAINT "job_module_needles_needle_id_job_module_id" UNIQUE ("needle_id", "job_module_id")
);
CREATE INDEX "job_module_needles_idx_job_module_id" on "job_module_needles" ("job_module_id");
CREATE INDEX "job_module_needles_idx_needle_id" on "job_module_needles" ("needle_id");

;
CREATE TABLE "needles" (
  "id" serial NOT NULL,
  "filename" text NOT NULL,
  "first_seen_module_id" integer NOT NULL,
  "last_seen_module_id" integer NOT NULL,
  "last_matched_module_id" integer,
  PRIMARY KEY ("id"),
  CONSTRAINT "needles_filename" UNIQUE ("filename")
);
CREATE INDEX "needles_idx_first_seen_module_id" on "needles" ("first_seen_module_id");
CREATE INDEX "needles_idx_last_matched_module_id" on "needles" ("last_matched_module_id");
CREATE INDEX "needles_idx_last_seen_module_id" on "needles" ("last_seen_module_id");

;
ALTER TABLE "job_module_needles" ADD CONSTRAINT "job_module_needles_fk_job_module_id" FOREIGN KEY ("job_module_id")
  REFERENCES "job_modules" ("id") DEFERRABLE;

;
ALTER TABLE "job_module_needles" ADD CONSTRAINT "job_module_needles_fk_needle_id" FOREIGN KEY ("needle_id")
  REFERENCES "needles" ("id") DEFERRABLE;

;
ALTER TABLE "needles" ADD CONSTRAINT "needles_fk_first_seen_module_id" FOREIGN KEY ("first_seen_module_id")
  REFERENCES "job_modules" ("id") DEFERRABLE;

;
ALTER TABLE "needles" ADD CONSTRAINT "needles_fk_last_matched_module_id" FOREIGN KEY ("last_matched_module_id")
  REFERENCES "job_modules" ("id") DEFERRABLE;

;
ALTER TABLE "needles" ADD CONSTRAINT "needles_fk_last_seen_module_id" FOREIGN KEY ("last_seen_module_id")
  REFERENCES "job_modules" ("id") DEFERRABLE;

;

COMMIT;

