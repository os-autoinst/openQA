PRAGMA foreign_keys=ON;
BEGIN TRANSACTION;
CREATE TABLE job_states (id INTEGER PRIMARY KEY, name TEXT);
INSERT INTO "job_states" VALUES(1,'scheduled');
INSERT INTO "job_states" VALUES(2,'running');
INSERT INTO "job_states" VALUES(3,'cancelled');
INSERT INTO "job_states" VALUES(4,'waiting');
INSERT INTO "job_states" VALUES(5,'done');
CREATE TABLE workers(
       id INTEGER PRIMARY KEY,

       host TEXT,
       instance INTEGER,
       backend TEXT,

       t_created TIMESTAMP,
       t_updated TIMESTAMP,

       UNIQUE(host, instance)
);

CREATE TRIGGER workers_t_updated AFTER UPDATE ON workers
BEGIN
    update workers SET t_updated = datetime('now') WHERE id = NEW.id;
END;

CREATE TRIGGER workers_t_created AFTER INSERT ON workers
BEGIN
    update workers SET t_created = datetime('now') WHERE id = NEW.id;
END;

INSERT INTO workers (id, t_created) VALUES(0, datetime('now'));

CREATE TABLE jobs (
       id INTEGER PRIMARY KEY,

       name TEXT,
       state_id INTEGER DEFAULT 1 REFERENCES job_states(id),
       priority INTEGER DEFAULT 50, -- 0-99
       result TEXT,
       worker_id INTEGER DEFAULT 0 REFERENCES workers(id) ON DELETE SET DEFAULT,
       t_started TIMESTAMP,
       t_finished TIMESTAMP,

       t_created TIMESTAMP,
       t_updated TIMESTAMP,

       UNIQUE(name)
);
CREATE TRIGGER jobs_t_updated AFTER UPDATE ON jobs
BEGIN
    update jobs SET t_updated = datetime('now') WHERE id = NEW.id;
END;

CREATE TRIGGER jobs_t_created AFTER INSERT ON jobs
BEGIN
    update jobs SET t_created = datetime('now') WHERE id = NEW.id;
END;

CREATE TABLE job_properties( -- stuff like distro, version, arch etc
       id INTEGER PRIMARY KEY,

       key TEXT,
       value TEXT,

       job_id INTEGER REFERENCES jobs(id) ON DELETE CASCADE,

       t_created TIMESTAMP,
       t_updated TIMESTAMP
);
CREATE TRIGGER job_properties_t_updated AFTER UPDATE ON job_properties
BEGIN
    update job_properties SET t_updated = datetime('now') WHERE id = NEW.id;
END;

CREATE TRIGGER job_properties_t_created AFTER INSERT ON job_properties
BEGIN
    update job_properties SET t_created = datetime('now') WHERE id = NEW.id;
END;

CREATE TABLE job_settings( -- environment settings for os-autoinst
       id INTEGER PRIMARY KEY,

       key TEXT,
       value TEXT,

       job_id INTEGER REFERENCES jobs(id) ON DELETE CASCADE,

       t_created TIMESTAMP,
       t_updated TIMESTAMP
);
CREATE TRIGGER job_settings_t_updated AFTER UPDATE ON job_settings
BEGIN
    update job_settings SET t_updated = datetime('now') WHERE id = NEW.id;
END;

CREATE TRIGGER job_settings_t_created AFTER INSERT ON job_settings
BEGIN
    update job_settings SET t_created = datetime('now') WHERE id = NEW.id;
END;

CREATE TABLE commands(
       id INTEGER PRIMARY KEY,

       command TEXT,
       t_processed TIMESTAMP,

       worker_id INTEGER REFERENCES workers(id),

       t_created TIMESTAMP,
       t_updated TIMESTAMP
);
CREATE TRIGGER commands_t_updated AFTER UPDATE ON commands
BEGIN
    update commands SET t_updated = datetime('now') WHERE id = NEW.id;
END;

CREATE TRIGGER commands_t_created AFTER INSERT ON commands
BEGIN
    update commands SET t_created = datetime('now') WHERE id = NEW.id;
END;

COMMIT;
