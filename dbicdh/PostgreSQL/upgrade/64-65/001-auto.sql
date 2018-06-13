-- Convert schema '/hdd/openqa-devel/repos/openQA/script/../dbicdh/_source/deploy/64/001-auto.yml' to '/hdd/openqa-devel/repos/openQA/script/../dbicdh/_source/deploy/65/001-auto.yml':;

;
BEGIN;

;
CREATE TABLE developer_sessions (
  job_id integer NOT NULL,
  user_id integer NOT NULL,
  ws_connection_count integer DEFAULT 0 NOT NULL,
  t_created timestamp NOT NULL,
  t_updated timestamp NOT NULL,
  PRIMARY KEY (job_id)
);
CREATE INDEX developer_sessions_idx_user_id on developer_sessions (user_id);

;
ALTER TABLE developer_sessions ADD CONSTRAINT developer_sessions_fk_job_id FOREIGN KEY (job_id)
  REFERENCES jobs (id) ON DELETE CASCADE DEFERRABLE;

;
ALTER TABLE developer_sessions ADD CONSTRAINT developer_sessions_fk_user_id FOREIGN KEY (user_id)
  REFERENCES users (id) DEFERRABLE;

;

COMMIT;

