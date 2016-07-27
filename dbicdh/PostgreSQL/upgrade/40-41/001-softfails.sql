BEGIN;

UPDATE job_modules SET result = 'softfailed' WHERE ( (  soft_failure > 0 AND result = 'passed' ) );

UPDATE jobs SET result = 'softfailed' WHERE ( ( id IN ( SELECT me.job_id FROM job_modules me WHERE (  soft_failure > 0  ) ) AND result = 'passed' ) );

COMMIT;
