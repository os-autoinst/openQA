use Test::Most;
use Test::Warnings qw(:no_end_test :report_warnings);
use Feature::Compat::Try;
# no OpenQA::Test::TimeLimit for this trivial test

eval 'use Test::Pod; 1' or plan skip_all => "Test::Pod required for testing POD";

all_pod_files_ok();
