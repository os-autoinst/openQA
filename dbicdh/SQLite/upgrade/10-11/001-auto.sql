-- Convert schema '/space/lnussel/git/openQA/script/../dbicdh/_source/deploy/10/001-auto.yml' to '/space/lnussel/git/openQA/script/../dbicdh/_source/deploy/11/001-auto.yml':;

;
BEGIN;

;
DROP INDEX products_distri_arch_flavor;

;
DROP INDEX products_name;

;
ALTER TABLE products ADD COLUMN version text NOT NULL DEFAULT '';

;
CREATE UNIQUE INDEX products_distri_version_arch_flavor ON products (distri, version, arch, flavor);

;

COMMIT;

