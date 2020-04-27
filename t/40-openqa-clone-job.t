#!/usr/bin/env perl
# Copyright (C) 2019-2020 SUSE LLC
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along
# with this program; if not, write to the Free Software Foundation, Inc.,
# 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.

use strict;
use warnings;
use Test::Exception;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/lib";
use Date::Format 'time2str';
use Mojo::File qw(path curfile tempfile);
use OpenQA::Test::Utils qw(run_cmd test_cmd stop_service);
use OpenQA::Test::Database;

sub test_once {
    # Report failure at the callsite instead of the test function
    local $Test::Builder::Level = $Test::Builder::Level + 1;
    # prevent all network access to stay local
    test_cmd(path(curfile->dirname, '../script/openqa-clone-job')->realpath, @_);
}

test_once '', qr/missing.*help for usage/, 'hint shown for mandatory parameter missing', 255, 'needs parameters';
test_once '--help',        qr/Usage:/, 'help text shown',              0, 'help screen is success';
test_once '--invalid-arg', qr/Usage:/, 'invalid args also yield help', 1, 'help screen on invalid not success';
my $args = 'http://openqa.opensuse.org/t1';
test_once $args, qr/failed to get job '1'/, 'fails without network', 1, 'fail';

my $apikey    = 'ARTHURKEY01';
my $apisecret = 'EXCALIBUR';
my $mojoport  = Mojo::IOLoop::Server->generate_port;
my $host      = "http://localhost:$mojoport";
my $schema    = OpenQA::Test::Database->new->create;
my $pid       = OpenQA::Test::Utils::create_webapi($mojoport, sub { });
END { stop_service $pid; }

my $jobs             = $schema->resultset('Jobs');
my $job_dependencies = $schema->resultset('JobDependencies');

subtest 'test START_DIRECTLY_AFTER_TEST' => sub {
    my $child_id   = '99996';
    my $parent_id  = '99995';
    my $job_params = {
        id         => $child_id,
        group_id   => 1001,
        priority   => 50,
        result     => OpenQA::Jobs::Constants::FAILED,
        state      => OpenQA::Jobs::Constants::DONE,
        TEST       => 'child_job',
        VERSION    => '13.1',
        BUILD      => '0091',
        ARCH       => 'i586',
        MACHINE    => '32bit',
        DISTRI     => 'opensuse',
        FLAVOR     => 'DVD',
        t_finished => time2str('%Y-%m-%d %H:%M:%S', time - 36000, 'UTC'),
        t_started  => time2str('%Y-%m-%d %H:%M:%S', time - 72000, 'UTC'),
        t_created  => time2str('%Y-%m-%d %H:%M:%S', time - 72000, 'UTC'),
        settings   => [{key => 'START_DIRECTLY_AFTER_TEST', value => 'parent_job'}],
    };
    $jobs->create($job_params);
    $job_params->{id}   = $parent_id;
    $job_params->{TEST} = 'parent_job';
    delete $job_params->{settings};
    $jobs->create($job_params);
    $job_dependencies->create(
        {
            child_job_id  => $child_id,
            parent_job_id => $parent_id,
            dependency    => OpenQA::JobDependencies::Constants::DIRECTLY_CHAINED,
        });
    my $tmp_file = tempfile;
    my $clone_args
      = "--from $host --host $host $child_id --apikey $apikey --apisecret $apisecret --skip-download > $tmp_file";
    test_once "$clone_args", qr//, 'do not check the output', 0, 'openqa-clone-job was executed successfully';
    my @jobs_id = sort { $a <=> $b } Mojo::File->new($tmp_file)->slurp =~ m/Created job #(\d+)/gm;
    is(scalar(@jobs_id), 2, 'two jobs were triggered');
    my $dependency = $job_dependencies->search({parent_job_id => $jobs_id[0], child_job_id => $jobs_id[1]})->first;
    ok defined $dependency, 'the relationship was built';
    is(
        $dependency->dependency,
        OpenQA::JobDependencies::Constants::DIRECTLY_CHAINED,
        'the DIRECTLY_CHAINED was built successfully'
    );
};

done_testing();
