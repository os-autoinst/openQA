-- Convert schema '/hdd/openqa-devel/repos/openQA/script/../dbicdh/_source/deploy/94/001-auto.yml' to '/hdd/openqa-devel/repos/openQA/script/../dbicdh/_source/deploy/95/001-auto.yml':;

;
BEGIN;

;
ALTER TABLE assets ALTER COLUMN id TYPE bigint;

;
ALTER TABLE assets ALTER COLUMN last_use_job_id TYPE bigint;

;
ALTER TABLE comments ALTER COLUMN job_id TYPE bigint;

;
ALTER TABLE developer_sessions ALTER COLUMN job_id TYPE bigint;

;
ALTER TABLE gru_dependencies ALTER COLUMN job_id TYPE bigint;

;
ALTER TABLE job_dependencies ALTER COLUMN child_job_id TYPE bigint;

;
ALTER TABLE job_dependencies ALTER COLUMN parent_job_id TYPE bigint;

;
ALTER TABLE job_modules ALTER COLUMN job_id TYPE bigint;

;
ALTER TABLE job_networks ALTER COLUMN job_id TYPE bigint;

;
ALTER TABLE job_settings ALTER COLUMN id TYPE bigint;

;
ALTER TABLE job_settings ALTER COLUMN job_id TYPE bigint;

;
ALTER TABLE jobs ALTER COLUMN id TYPE bigint;

;
ALTER TABLE jobs ALTER COLUMN clone_id TYPE bigint;

;
ALTER TABLE jobs ALTER COLUMN blocked_by_id TYPE bigint;

;
ALTER TABLE jobs ALTER COLUMN assigned_worker_id TYPE bigint;

;
ALTER TABLE jobs_assets ALTER COLUMN job_id TYPE bigint;

;
ALTER TABLE jobs_assets ALTER COLUMN asset_id TYPE bigint;

;
ALTER TABLE screenshot_links ALTER COLUMN job_id TYPE bigint;

;
ALTER TABLE workers ALTER COLUMN job_id TYPE bigint;

;

COMMIT;

