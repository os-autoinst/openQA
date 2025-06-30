-- Convert schema '/home/dheidler/openqa/repos/openQA/script/../dbicdh/_source/deploy/100/001-auto.yml' to '/home/dheidler/openqa/repos/openQA/script/../dbicdh/_source/deploy/101/001-auto.yml':;

;
BEGIN;

;
ALTER TABLE job_group_parents ALTER COLUMN build_version_sort DROP DEFAULT;
ALTER TABLE job_group_parents ALTER COLUMN build_version_sort TYPE integer USING (build_version_sort::integer);
ALTER TABLE job_group_parents ALTER COLUMN build_version_sort SET DEFAULT 1;

;
ALTER TABLE job_groups ALTER COLUMN build_version_sort DROP DEFAULT;
ALTER TABLE job_groups ALTER COLUMN build_version_sort TYPE integer USING (build_version_sort::integer);
ALTER TABLE job_groups ALTER COLUMN build_version_sort SET DEFAULT 1;

;

COMMIT;






