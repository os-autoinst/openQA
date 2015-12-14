-- Convert schema '/home/openQA/openQA/script/../dbicdh/_source/deploy/35/001-auto.yml' to '/home/openQA/openQA/script/../dbicdh/_source/deploy/36/001-auto.yml':;

;
BEGIN;

;
CREATE TABLE "audit_events" (
  "id" serial NOT NULL,
  "user_id" integer,
  "connection_id" text,
  "event" text NOT NULL,
  "event_data" text,
  "t_created" timestamp NOT NULL,
  "t_updated" timestamp NOT NULL,
  PRIMARY KEY ("id")
);
CREATE INDEX "audit_events_idx_user_id" on "audit_events" ("user_id");

;
ALTER TABLE "audit_events" ADD CONSTRAINT "audit_events_fk_user_id" FOREIGN KEY ("user_id")
  REFERENCES "users" ("id") DEFERRABLE;

;

COMMIT;

