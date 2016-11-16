-- Convert schema '/home/coolo/prod/openQA/script/../dbicdh/_source/deploy/47/001-auto.yml' to '/home/coolo/prod/openQA/script/../dbicdh/_source/deploy/48/001-auto.yml':;

;
BEGIN;

;
CREATE TABLE "screenshot_links" (
  "screenshot_id" integer NOT NULL,
  "job_id" integer NOT NULL
);
CREATE INDEX "screenshot_links_idx_job_id" on "screenshot_links" ("job_id");
CREATE INDEX "screenshot_links_idx_screenshot_id" on "screenshot_links" ("screenshot_id");

;
CREATE TABLE "screenshots" (
  "id" serial NOT NULL,
  "filename" text NOT NULL,
  "t_created" timestamp NOT NULL,
  PRIMARY KEY ("id"),
  CONSTRAINT "screenshots_filename" UNIQUE ("filename")
);

;
ALTER TABLE "screenshot_links" ADD CONSTRAINT "screenshot_links_fk_job_id" FOREIGN KEY ("job_id")
  REFERENCES "jobs" ("id") ON DELETE CASCADE ON UPDATE CASCADE DEFERRABLE;

;
ALTER TABLE "screenshot_links" ADD CONSTRAINT "screenshot_links_fk_screenshot_id" FOREIGN KEY ("screenshot_id")
  REFERENCES "screenshots" ("id") DEFERRABLE;

;

COMMIT;

