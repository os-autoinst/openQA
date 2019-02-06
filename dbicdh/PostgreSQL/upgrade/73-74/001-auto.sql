-- Convert schema '/hdd/openqa-devel/repos/openQA/script/../dbicdh/_source/deploy/73/001-auto.yml' to '/hdd/openqa-devel/repos/openQA/script/../dbicdh/_source/deploy/74/001-auto.yml':;

;
BEGIN;

;
ALTER TABLE developer_sessions DROP CONSTRAINT developer_sessions_fk_user_id;

;
ALTER TABLE developer_sessions ADD CONSTRAINT developer_sessions_fk_user_id FOREIGN KEY (user_id)
  REFERENCES users (id) ON DELETE CASCADE ON UPDATE CASCADE DEFERRABLE;

;
ALTER TABLE jobs ADD COLUMN externally_skipped_module_count integer DEFAULT 0 NOT NULL;

;

COMMIT;

