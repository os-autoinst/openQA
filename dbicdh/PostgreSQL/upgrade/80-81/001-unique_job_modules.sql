-- Bad timing of status updates from the worker to the webui could sometimes
-- result in duplicate records due to a missing unique constraint on the table
DELETE FROM job_modules WHERE id IN (
    SELECT id FROM (
        SELECT id, ROW_NUMBER() OVER (
            PARTITION BY job_id, name, category, script
            ORDER BY id
        ) as row_num FROM job_modules
    ) as t WHERE t.row_num > 1
);
