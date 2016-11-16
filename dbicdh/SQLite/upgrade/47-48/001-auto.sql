-- Convert schema '/home/coolo/prod/openQA/script/../dbicdh/_source/deploy/47/001-auto.yml' to '/home/coolo/prod/openQA/script/../dbicdh/_source/deploy/48/001-auto.yml':;

;
BEGIN;

;
CREATE TABLE screenshot_links (
  screenshot_id integer NOT NULL,
  job_id integer NOT NULL,
  FOREIGN KEY (job_id) REFERENCES jobs(id) ON DELETE CASCADE ON UPDATE CASCADE,
  FOREIGN KEY (screenshot_id) REFERENCES screenshots(id)
);

;
CREATE INDEX screenshot_links_idx_job_id ON screenshot_links (job_id);

;
CREATE INDEX screenshot_links_idx_screenshot_id ON screenshot_links (screenshot_id);

;
CREATE TABLE screenshots (
  id INTEGER PRIMARY KEY NOT NULL,
  filename text NOT NULL,
  t_created timestamp NOT NULL
);

;
CREATE UNIQUE INDEX screenshots_filename ON screenshots (filename);

;

COMMIT;

