-- Convert schema '/hdd/openqa-devel/repos/openQA/script/../dbicdh/_source/deploy/79/001-auto.yml' to '/hdd/openqa-devel/repos/openQA/script/../dbicdh/_source/deploy/80/001-auto.yml':;

;
BEGIN;

;
ALTER TABLE screenshot_links DROP CONSTRAINT screenshot_links_fk_screenshot_id;

;
ALTER TABLE screenshot_links ADD CONSTRAINT screenshot_links_fk_screenshot_id FOREIGN KEY (screenshot_id)
  REFERENCES screenshots (id) ON DELETE CASCADE ON UPDATE CASCADE DEFERRABLE;

;
ALTER TABLE screenshots ADD COLUMN link_count integer DEFAULT 0 NOT NULL;

;

COMMIT;

