#!/usr/bin/env perl
# Copyright 2019-2021 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;
use Test::Warnings qw(warning :report_warnings);
use FindBin;
use lib "$FindBin::Bin/lib", "$FindBin::Bin/../external/os-autoinst-common/lib";
use OpenQA::Test::TimeLimit '10';
use OpenQA::Test::Utils qw(run_cmd test_cmd);
use Test::MockModule;
$ENV{OPENQA_CONFIG} = '';

sub test_once {
    # Report failure at the callsite instead of the test function
    local $Test::Builder::Level = $Test::Builder::Level + 1;
    test_cmd('script/openqa-clone-job', @_);
}

require "$FindBin::Bin/../script/openqa-clone-job";
my $main = Test::MockModule->new('main');
$main->redefine(usage => 0);

my @apiargs = qw(--apikey foo --apisecret bar);

subtest 'usage' => sub {
    test_once '--help', qr/Usage:/, 'help text shown', 0, 'help screen is success';

    local @ARGV;
    throws_ok { main::main() } qr/missing.*help for usage/, 'hint shown for mandatory parameter missing';
    @ARGV = '--invalid-arg';
    like warning {
        throws_ok { main::main() } qr/missing job reference/, 'hit for mandatory parameter';
    }, qr{Unknown option: invalid-arg}, 'expected warning';

    @ARGV = 'http://openqa.local.foo/t1';
    throws_ok { main::main() } qr|API key/secret for 'localhost' missing|, 'fails without API key/secret';
};

subtest errors => sub {
    local @ARGV = (@apiargs, 'http://openqa.local.foo/t1');
    throws_ok { main::main() } qr/failed to get job '1'/, 'fails with non existing host';
};

subtest 'job argument' => sub {
    my $server = 'http://server.example';
    my $ip = 'http://10.20.30.40';
    my $schemeless = 'server.example';
    my $schemelessip = '10.20.30.40';
    my $localurl = 'http://localhost/api/v1/jobs';
    my @tests = (
        ["$server/tests/123", "$server", "$server/api/v1/jobs"],
        ["$ip/tests/123", "$ip", "$ip/api/v1/jobs"],
        ["$schemeless/tests/123", "http://$schemeless", "http://$schemeless/api/v1/jobs"],
        ["$schemelessip/tests/123", "http://$schemelessip", "http://$schemelessip/api/v1/jobs"],
    );
    for my $test (@tests) {
        subtest $test->[0] => sub {
            local @ARGV = (@apiargs, $test->[0]);
            my ($jobid, $options) = main::parse_options();
            is $jobid, 123, 'correct job id';
            is $options->{from}, $test->[1], 'correct from';

            my $url_handler = create_url_handler($options);
            is $url_handler->{local_url}, $localurl, 'correct local url';
            is $url_handler->{remote_url}, $test->[2], 'correct remote url';
        };
    }
};

subtest '--from vs. first argument' => sub {
    my $url = 'http://server.example/tests/123';
    local @ARGV = (@apiargs, '--from', $url);
    my ($jobid1, $options1) = main::parse_options();
    @ARGV = (@apiargs, $url);
    my ($jobid2, $options2) = main::parse_options();
    is $jobid2, $jobid1, 'same job id';
    is_deeply $options2, $options1, 'same options';
};

subtest '--within-instance' => sub {
    my $url = 'http://server.example/tests/123';
    local @ARGV = (@apiargs, '--within-instance', $url);
    my ($jobid, $options) = main::parse_options();
    is $jobid, 123, 'correct jobid';
    is $options->{from}, 'http://server.example', 'correct from';
    is $options->{host}, 'http://server.example', 'correct host';

    my $url_handler = create_url_handler($options);
    is $url_handler->{local_url}, 'http://server.example/api/v1/jobs', 'correct local url';
};

done_testing();
