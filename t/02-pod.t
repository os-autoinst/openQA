use Test::Most;
use Test::Warnings qw(:no_end_test :report_warnings);
# no OpenQA::Test::TimeLimit for this trivial test

eval 'use Test::Pod';
plan skip_all => "Test::Pod required for testing POD" if $@;

all_pod_files_ok();
