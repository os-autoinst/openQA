-- Convert schema '/usr/share/openqa/script/../dbicdh/_source/deploy/54/001-auto.yml' to '/usr/share/openqa/script/../dbicdh/_source/deploy/55/001-auto.yml':;

;
BEGIN;

;
CREATE TABLE "bugs" (
  "id" serial NOT NULL,
  "bugid" text NOT NULL,
  "title" text,
  "priority" text,
  "assigned" boolean,
  "assignee" text,
  "open" boolean,
  "status" text,
  "resolution" text,
  "existing" boolean DEFAULT '1' NOT NULL,
  "refreshed" boolean DEFAULT '0' NOT NULL,
  "t_created" timestamp NOT NULL,
  "t_updated" timestamp NOT NULL,
  PRIMARY KEY ("id"),
  CONSTRAINT "bugs_bugid" UNIQUE ("bugid")
);

;

COMMIT;

