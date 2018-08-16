#! /usr/bin/perl

# Copyright (C) 2018 SUSE LLC
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

BEGIN {
    unshift @INC, 'lib';
}

use FindBin;
use lib "$FindBin::Bin/lib";
use Mojo::Base -strict;
use Test::More;
use Test::Mojo;
use Test::Warnings;
use Test::MockModule;
use Test::Output qw(stdout_like);
use OpenQA::Test::Case;
use OpenQA::Task::Asset::Limit;

# allow catching log messages via stdout_like
delete $ENV{OPENQA_LOGFILE};

# init test case
my $test_case = OpenQA::Test::Case->new;
$test_case->init_data;
my $t = Test::Mojo->new('OpenQA::WebAPI');

my $schema = $t->app->schema;
$schema->resultset('Assets')->scan_for_untracked_assets();
$schema->resultset('Assets')->refresh_assets();

# prevent files being actually deleted
my $mock_asset = new Test::MockModule('OpenQA::Schema::Result::Assets');
$mock_asset->mock(remove_from_disk          => sub { return 1; });
$mock_asset->mock(refresh_assets            => sub { });
$mock_asset->mock(scan_for_untracked_assets => sub { });

subtest 'limit for keeping untracked assets is overridable in settings' => sub {
    stdout_like(
        sub {
            OpenQA::Task::Asset::Limit::_limit($t->app);
        },
        qr/Asset iso\/Core-7.2.iso is not in any job group, will delete in 14 days/,
        'default is 14 days'
    );

    $t->app->config->{misc_limits}->{untracked_assets_storage_duration} = 2;
    stdout_like(
        sub {
            OpenQA::Task::Asset::Limit::_limit($t->app);
        },
        qr/Asset iso\/Core-7.2.iso is not in any job group, will delete in 2 days/,
        'override works'
    );
};

done_testing();
