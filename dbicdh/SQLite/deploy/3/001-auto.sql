-- 
-- Created by SQL::Translator::Producer::SQLite
-- Created on Wed Mar 26 17:01:32 2014
-- 

;
BEGIN TRANSACTION;
--
-- Table: job_results
--
CREATE TABLE job_results (
  id INTEGER PRIMARY KEY NOT NULL,
  name text NOT NULL
);
--
-- Table: job_settings
--
CREATE TABLE job_settings (
  id INTEGER PRIMARY KEY NOT NULL,
  key text NOT NULL,
  value text NOT NULL,
  job_id integer NOT NULL,
  t_created timestamp,
  t_updated timestamp,
  FOREIGN KEY (job_id) REFERENCES jobs(id) ON DELETE CASCADE ON UPDATE CASCADE
);
CREATE INDEX job_settings_idx_job_id ON job_settings (job_id);
--
-- Table: job_states
--
CREATE TABLE job_states (
  id INTEGER PRIMARY KEY NOT NULL,
  name text NOT NULL
);
--
-- Table: secrets
--
CREATE TABLE secrets (
  id INTEGER PRIMARY KEY NOT NULL,
  secret text NOT NULL,
  t_created timestamp,
  t_updated timestamp
);
CREATE UNIQUE INDEX constraint_name ON secrets (secret);
--
-- Table: users
--
CREATE TABLE users (
  id INTEGER PRIMARY KEY NOT NULL,
  openid text NOT NULL,
  is_operator integer NOT NULL DEFAULT 0,
  is_admin integer NOT NULL DEFAULT 0,
  t_created timestamp,
  t_updated timestamp
);
CREATE UNIQUE INDEX constraint_name02 ON users (openid);
--
-- Table: workers
--
CREATE TABLE workers (
  id INTEGER PRIMARY KEY NOT NULL,
  host text NOT NULL,
  instance integer NOT NULL,
  backend text NOT NULL,
  t_created timestamp,
  t_updated timestamp
);
CREATE UNIQUE INDEX constraint_name03 ON workers (host, instance);
--
-- Table: api_keys
--
CREATE TABLE api_keys (
  id INTEGER PRIMARY KEY NOT NULL,
  key text NOT NULL,
  secret text NOT NULL,
  user_id integer NOT NULL,
  t_expiration timestamp,
  t_created timestamp,
  t_updated timestamp,
  FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE ON UPDATE CASCADE
);
CREATE INDEX api_keys_idx_user_id ON api_keys (user_id);
CREATE UNIQUE INDEX constraint_name04 ON api_keys (key);
--
-- Table: commands
--
CREATE TABLE commands (
  id INTEGER PRIMARY KEY NOT NULL,
  command text NOT NULL,
  t_processed timestamp,
  worker_id integer NOT NULL,
  t_created timestamp,
  t_updated timestamp,
  FOREIGN KEY (worker_id) REFERENCES workers(id) ON DELETE CASCADE ON UPDATE CASCADE
);
CREATE INDEX commands_idx_worker_id ON commands (worker_id);
--
-- Table: jobs
--
CREATE TABLE jobs (
  id INTEGER PRIMARY KEY NOT NULL,
  slug text,
  state_id integer NOT NULL DEFAULT 0,
  priority integer NOT NULL DEFAULT 50,
  result_id integer NOT NULL DEFAULT 0,
  worker_id integer NOT NULL DEFAULT 0,
  test text NOT NULL,
  test_branch text,
  t_started timestamp,
  t_finished timestamp,
  t_created timestamp,
  t_updated timestamp,
  FOREIGN KEY (result_id) REFERENCES job_results(id) ON DELETE CASCADE ON UPDATE CASCADE,
  FOREIGN KEY (state_id) REFERENCES job_states(id) ON DELETE CASCADE ON UPDATE CASCADE,
  FOREIGN KEY (worker_id) REFERENCES workers(id) ON DELETE CASCADE ON UPDATE CASCADE
);
CREATE INDEX jobs_idx_result_id ON jobs (result_id);
CREATE INDEX jobs_idx_state_id ON jobs (state_id);
CREATE INDEX jobs_idx_worker_id ON jobs (worker_id);
CREATE UNIQUE INDEX constraint_name05 ON jobs (slug);
CREATE TRIGGER trigger_job_settings_t_created after insert on job_settings BEGIN UPDATE job_settings SET t_created = datetime('now') WHERE id = NEW.id; END;
CREATE TRIGGER trigger_job_settings_t_updated after update on job_settings BEGIN UPDATE job_settings SET t_updated = datetime('now') WHERE id = NEW.id; END;
CREATE TRIGGER trigger_secrets_t_created after insert on secrets BEGIN UPDATE secrets SET t_created = datetime('now') WHERE id = NEW.id; END;
CREATE TRIGGER trigger_secrets_t_updated after update on secrets BEGIN UPDATE secrets SET t_updated = datetime('now') WHERE id = NEW.id; END;
CREATE TRIGGER trigger_users_t_created after insert on users BEGIN UPDATE users SET t_created = datetime('now') WHERE id = NEW.id; END;
CREATE TRIGGER trigger_users_t_updated after update on users BEGIN UPDATE users SET t_updated = datetime('now') WHERE id = NEW.id; END;
CREATE TRIGGER trigger_workers_t_created after insert on workers BEGIN UPDATE workers SET t_created = datetime('now') WHERE id = NEW.id; END;
CREATE TRIGGER trigger_workers_t_updated after update on workers BEGIN UPDATE workers SET t_updated = datetime('now') WHERE id = NEW.id; END;
CREATE TRIGGER trigger_api_keys_t_created after insert on api_keys BEGIN UPDATE api_keys SET t_created = datetime('now') WHERE id = NEW.id; END;
CREATE TRIGGER trigger_api_keys_t_updated after update on api_keys BEGIN UPDATE api_keys SET t_updated = datetime('now') WHERE id = NEW.id; END;
CREATE TRIGGER trigger_commands_t_created after insert on commands BEGIN UPDATE commands SET t_created = datetime('now') WHERE id = NEW.id; END;
CREATE TRIGGER trigger_commands_t_updated after update on commands BEGIN UPDATE commands SET t_updated = datetime('now') WHERE id = NEW.id; END;
CREATE TRIGGER trigger_jobs_t_created after insert on jobs BEGIN UPDATE jobs SET t_created = datetime('now') WHERE id = NEW.id; END;
CREATE TRIGGER trigger_jobs_t_updated after update on jobs BEGIN UPDATE jobs SET t_updated = datetime('now') WHERE id = NEW.id; END;
COMMIT;
