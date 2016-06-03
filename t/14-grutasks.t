#!/usr/bin/env perl -w

# Copyright (c) 2015 SUSE LINUX, Nuernberg, Germany.
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

BEGIN {
    unshift @INC, 'lib';
}

use strict;
use autodie qw(:all);
use OpenQA::Utils;
use File::Copy;
use OpenQA::Test::Database;
use Test::More;
use Test::Mojo;
use Test::Warnings;
use OpenQA::Test::Case;
use File::Which qw(which);

OpenQA::Test::Database->new->create();

my $t = Test::Mojo->new('OpenQA::WebAPI');

my $file = 't/data/7da661d0c3faf37d49d33b6fc308f2.png';
copy("t/images/34/.thumbs/7da661d0c3faf37d49d33b6fc308f2.png", $file);
is((stat($file))[7], 287, 'original file size');
$t->app->gru->enqueue(optipng => $file);

my $c = OpenQA::WebAPI::Plugin::Gru::Command::gru->new();
$c->app($t->app);

sub run_gru {
    my ($task, $args) = @_;

    $t->app->gru->enqueue($task => $args);
    $c->run('run', '-o');
}

open(FD, ">", \my $output);
select FD;
$c->run('list');
close(FD);
select STDOUT;
like($output, qr,optipng .*'$file';,, 'optipng queued');

$c->run('run', '-o');
if (which('optipng')) {
    is((stat($file))[7], 286, 'optimized file size');
}

# now to something completely different
run_gru('limit_assets');

ok(-f "t/data/openqa/factory/iso/openSUSE-13.1-DVD-i586-Build0091-Media.iso",   "iso 1 is still there");
ok(-f "t/data/openqa/factory/iso/openSUSE-13.1-DVD-x86_64-Build0091-Media.iso", "iso 2 is still there");

sub create_temp_job_result_file {
    my ($resultdir) = @_;

    my $filename = $resultdir . '/autoinst-log.txt';
    open my $fh, ">>$filename";
    close $fh;
    die 'temporary file could not be created' unless -e $filename;
    return $filename;
}

my @jobs      = $t->app->db->resultset('Jobs')->search({state => 'done'})->all;
my $resultdir = $jobs[1]->result_dir;
my $jobid     = $jobs[1]->id;
my %args      = (resultdir => $resultdir, jobid => $jobid);

subtest 'reduce_result gru task cleans up logs' => sub {
    my $filename = create_temp_job_result_file($resultdir);
    run_gru('reduce_result' => \%args);
    ok(!-e $filename, 'file got cleaned');
};

done_testing();
