-- Convert schema '/home/martchus/repos/openQA/script/../dbicdh/_source/deploy/46/001-auto.yml' to '/home/martchus/repos/openQA/script/../dbicdh/_source/deploy/47/001-auto.yml':;

;
BEGIN;

;
CREATE TABLE jobgroupsubscriptions (
  group_id integer NOT NULL,
  user_id integer NOT NULL,
  flags integer DEFAULT 0,
  t_created timestamp NOT NULL,
  t_updated timestamp NOT NULL,
  PRIMARY KEY (group_id, user_id),
  FOREIGN KEY (group_id) REFERENCES job_groups(id) ON DELETE CASCADE ON UPDATE CASCADE,
  FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE ON UPDATE CASCADE
);

;
CREATE INDEX jobgroupsubscriptions_idx_group_id ON jobgroupsubscriptions (group_id);

;
CREATE INDEX jobgroupsubscriptions_idx_user_id ON jobgroupsubscriptions (user_id);

;

COMMIT;

