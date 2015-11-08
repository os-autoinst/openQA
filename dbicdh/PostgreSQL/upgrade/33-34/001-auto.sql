-- Convert schema '/home/coolo/prod/openQA/script/../dbicdh/_source/deploy/33/001-auto.yml' to '/home/coolo/prod/openQA/script/../dbicdh/_source/deploy/34/001-auto.yml':;

;
BEGIN;

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

