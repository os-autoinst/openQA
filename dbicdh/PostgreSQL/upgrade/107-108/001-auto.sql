-- Convert schema '/home/okurz/local/os-autoinst/openQA/script/../dbicdh/_source/deploy/107/001-auto.yml' to '/home/okurz/local/os-autoinst/openQA/script/../dbicdh/_source/deploy/108/001-auto.yml':;

;
BEGIN;

;
CREATE TABLE ssh_keys (
  id bigserial NOT NULL,
  user_id bigint NOT NULL,
  title text NOT NULL,
  public_key text NOT NULL,
  fingerprint text NOT NULL,
  last_used timestamp,
  t_expiration timestamp,
  t_created timestamp NOT NULL,
  t_updated timestamp NOT NULL,
  PRIMARY KEY (id),
  CONSTRAINT ssh_keys_fingerprint UNIQUE (fingerprint)
);
CREATE INDEX ssh_keys_idx_user_id on ssh_keys (user_id);

;
ALTER TABLE ssh_keys ADD CONSTRAINT ssh_keys_fk_user_id FOREIGN KEY (user_id)
  REFERENCES users (id) ON DELETE CASCADE ON UPDATE CASCADE DEFERRABLE;

;

COMMIT;

