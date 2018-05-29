update needles set last_seen_time=data.t_created from (select id,t_created from job_modules) data where needles.last_seen_module_id=data.id;
update needles set last_matched_time=data.t_created from (select id,t_created from job_modules) data where needles.last_matched_module_id=data.id;

