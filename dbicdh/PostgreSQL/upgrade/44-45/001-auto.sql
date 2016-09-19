-- Convert schema '/space/prod/openQA/script/../dbicdh/_source/deploy/44/001-auto.yml' to '/space/prod/openQA/script/../dbicdh/_source/deploy/45/001-auto.yml':;

create index gru_tasks_run_at_reversed on gru_tasks (run_at DESC);
delete from gru_tasks where taskname='optipng';

-- No differences found;

