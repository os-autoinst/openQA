# Copyright (C) 2017 SUSE LLC
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
use warnings;
use FindBin;
use lib "$FindBin::Bin/lib";
use OpenQA::ServerStartup;
use OpenQA::Utils;
use Test::More;
use Mojolicious;
use Mojo::File qw(tempfile path);

subtest 'Setup logging to file' => sub {
    local $ENV{OPENQA_LOGFILE} = undef;
    my $tempfile = tempfile;
    my $app = Mojolicious->new(config => {logging => {file => $tempfile}});
    OpenQA::ServerStartup::setup_logging($app);
    $app->attr('log_name', sub { return "test"; });

    my $log = $app->log;
    $log->error('Just works');
    $log->fatal('Fatal error');
    $log->debug('It works');
    $log->info('Works too');

    my $content = $tempfile->slurp;
    like $content, qr/\[.*\] \[test:error\] Just works/,  'right error message';
    like $content, qr/\[.*\] \[test:fatal\] Fatal error/, 'right fatal message';
    like $content, qr/\[.*\] \[test:debug\] It works/,    'right debug message';
    like $content, qr/\[.*\] \[test:info\] Works too/,    'right info message';
};

subtest 'Setup logging to STDERR' => sub {
    local $ENV{OPENQA_LOGFILE} = undef;
    my $buffer = '';
    my $app    = Mojolicious->new();
    OpenQA::ServerStartup::setup_logging($app);
    {
        open my $handle, '>', \$buffer;
        local *STDERR = $handle;
        my $log = $app->log;
        $log->error('Just works');
        $log->fatal('Fatal error');
        $log->debug('It works');
        $log->info('Works too');
    }
    like $buffer, qr/\[test:error\] Just works\n/,  'right error message';
    like $buffer, qr/\[test:fatal\] Fatal error\n/, 'right fatal message';
    like $buffer, qr/\[test:debug\] It works\n/,    'right debug message';
    like $buffer, qr/\[test:info\] Works too\n/,    'right info message';
};

subtest 'Setup logging to file (ENV)' => sub {
    local $ENV{OPENQA_LOGFILE} = tempfile;
    my $app = Mojolicious->new(config => {logging => {file => "/tmp/ignored_foo_bar"}});
    OpenQA::ServerStartup::setup_logging($app);
    $app->attr('log_name', sub { return "test"; });

    my $log = $app->log;
    $log->error('Just works');
    $log->fatal('Fatal error');
    $log->debug('It works');
    $log->info('Works too');

    my $content = path($ENV{OPENQA_LOGFILE})->slurp;
    like $content, qr/\[.*\] \[test:error\] Just works/,  'right error message';
    like $content, qr/\[.*\] \[test:fatal\] Fatal error/, 'right fatal message';
    like $content, qr/\[.*\] \[test:debug\] It works/,    'right debug message';
    like $content, qr/\[.*\] \[test:info\] Works too/,    'right info message';
    ok !-e "/tmp/ignored_foo_bar";

    $app = Mojolicious->new();
    OpenQA::ServerStartup::setup_logging($app);
    $app->attr('log_name', sub { return "test"; });

    $log = $app->log;
    $log->error('Just works');
    $log->fatal('Fatal error');
    $log->debug('It works');
    $log->info('Works too');

    $content = path($ENV{OPENQA_LOGFILE})->slurp;
    like $content, qr/\[.*\] \[test:error\] Just works/,  'right error message';
    like $content, qr/\[.*\] \[test:fatal\] Fatal error/, 'right fatal message';
    like $content, qr/\[.*\] \[test:debug\] It works/,    'right debug message';
    like $content, qr/\[.*\] \[test:info\] Works too/,    'right info message';
};

done_testing();

package db_profiler;
no warnings 'redefine';
sub enable_sql_debugging {
    1;
}
