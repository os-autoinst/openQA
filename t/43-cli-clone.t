# Copyright (C) 2020 SUSE LLC
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
# with this program; if not, see <http://www.gnu.org/licenses/>.

use Mojo::Base -strict;

use FindBin;
use lib "$FindBin::Bin/lib";

use Test::More;
use Capture::Tiny qw(capture_stdout);
use Mojo::Server::Daemon;
use Mojo::File qw(tempdir tempfile);
use OpenQA::CLI;
use OpenQA::CLI::clone;
use OpenQA::Test::Case;

OpenQA::Test::Case->new->init_data;

# Mock WebAPI with extra test routes
my $daemon = Mojo::Server::Daemon->new(listen => ['http://127.0.0.1']);
my $app    = $daemon->build_app('OpenQA::WebAPI');
$app->log->level('error');
my $port = $daemon->start->ports->[0];
my $host = "http://127.0.0.1:$port";

# Default options for authentication tests
my @auth = ('--apikey', 'ARTHURKEY01', '--apisecret', 'EXCALIBUR', '--host', $host);

my $cli   = OpenQA::CLI->new;
my $clone = OpenQA::CLI::clone->new;

subtest 'Help' => sub {
    my ($stdout, @result) = capture_stdout sub { $cli->run('help', 'clone') };
    like $stdout, qr/Usage: openqa-cli clone/, 'help';
};

subtest 'Clone invalid job' => sub {
    my $jobid = 12345;

    eval { $clone->run('--from', $host, $jobid) };
    like $@, qr/failed to get job '$jobid'/, 'error because job is invalid';

    is $clone->jobid, $jobid, 'specified jobid';
    is $clone->host, 'http://localhost', 'default host';
    is $clone->options->{from}, $host, 'specified from';
    is $clone->options->{dir}, '/var/lib/openqa/factory', 'default dir';
};

subtest 'Clone within instance' => sub {
    my $jobid = 12345;

    eval { $clone->run('--within-instance', $host, $jobid) };
    like $@, qr/failed to get job '$jobid'/, 'error because job is invalid';

    is $clone->jobid, $jobid, 'specified jobid';
    is $clone->host,  $host,  'same host';
    is $clone->options->{from}, $host, 'specified from';
    is $clone->options->{'skip-download'}, 1, 'skip download set';
};

subtest 'Clone job' => sub {
    my $jobid = 99937;
    my $dir   = tempdir("/tmp/$FindBin::Script-XXXX")->make_path;
    my @args  = ('--dir', $dir, '--host', $host, '--from', $host, $jobid);

    eval { $clone->run(@args) };
    like $@, qr/can't write $dir/, 'error because folder does not exist';

    $dir->child('iso')->make_path;
    eval { $clone->run(@args) };
    like $@, qr/$jobid failed: 500 read timeout/, 'error because asset does not exist';

    is $clone->host,  $host,  'specified host';
    is $clone->jobid, $jobid, 'specified jobid';
    is $clone->options->{from}, $host, 'specified from';
    is $clone->options->{dir},  $dir,  'specified dir';
};

done_testing();
