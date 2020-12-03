use Test::Most;
use Test::Warnings ':report_warnings';
use FindBin;
use lib "$FindBin::Bin/lib", "$FindBin::Bin/../external/os-autoinst-common/lib";
use OpenQA::Test::TimeLimit '80';

#is(system('ls', '-a'), 0, "tidy");
system('docker', 'build', '-t', 'docker_webui', 'docker/webui');


done_testing();
