-- Convert schema '/home/sri/work/openQA/repos/openQA/script/../dbicdh/_source/deploy/100/001-auto.yml' to '/home/sri/work/openQA/repos/openQA/script/../dbicdh/_source/deploy/101/001-auto.yml':;

;
BEGIN;

;
CREATE INDEX idx_assigned_worker_id_t_finished on jobs (assigned_worker_id, t_finished);

;

COMMIT;

