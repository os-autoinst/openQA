-- Convert schema '/hdd/openqa-devel/repos/openQA/script/../dbicdh/_source/deploy/66/001-auto.yml' to '/hdd/openqa-devel/repos/openQA/script/../dbicdh/_source/deploy/67/001-auto.yml':;

;
BEGIN;

;
ALTER TABLE comments ADD COLUMN parent_group_id integer;

;
CREATE INDEX comments_idx_parent_group_id on comments (parent_group_id);

;
ALTER TABLE comments ADD CONSTRAINT comments_fk_parent_group_id FOREIGN KEY (parent_group_id)
  REFERENCES job_group_parents (id) ON DELETE CASCADE ON UPDATE CASCADE DEFERRABLE;

;

COMMIT;

