-- Convert schema '/space/prod/openQA/script/../dbicdh/_source/deploy/47/001-auto.yml' to '/space/prod/openQA/script/../dbicdh/_source/deploy/48/001-auto.yml':;

;
BEGIN;

;
CREATE TABLE "screenshots" (
  "id" serial NOT NULL,
  "filename" text NOT NULL,
  "t_created" timestamp NOT NULL,
  PRIMARY KEY ("id"),
  CONSTRAINT "screenshots_filename" UNIQUE ("filename")
);

;

COMMIT;

