#! /usr/bin/perl

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

use Mojo::Base -strict;

use FindBin;
use lib "$FindBin::Bin/../lib";
#use Test::More;
use Test::Most;
use Test::MockModule 'strict';
use Test::Mojo;
use Test::Output;
use Test::Warnings;
use OpenQA::Test::Case;
use OpenQA::Client;

#die_on_fail;

OpenQA::Test::Case->new->init_data(fixture_files => '03-users.pl');
my $t = Test::Mojo->new('OpenQA::WebAPI');
my $app = $t->app;
my @client_config = (apikey => 'PERCIVALKEY02', apisecret => 'PERCIVALSECRET02');
$t->ua(OpenQA::Client->new(@client_config)->ioloop(Mojo::IOLoop->singleton));
$t->app($app);

my $schema             = $t->app->schema;
my $jobs               = $schema->resultset('Jobs');

sub schedule_iso {
    my ($args, $status, $query_params) = @_;
    $status //= 200;

    my $url = Mojo::URL->new('/api/v1/isos');
    $url->query($query_params);

    $t->post_ok($url, form => $args)->status_is($status);
    return $t->tx->res;
}

my $iso = 'openSUSE-13.1-DVD-i586-Build0091-Media.iso';
# TODO create git repo in temp dir
my $distri = 'file:///path/to/temp/foo.git';
my %iso = (ISO => $iso, DISTRI => $distri, VERSION => '13.1', FLAVOR => 'DVD', ARCH => 'i586', BUILD => '0091');

subtest 'job templates defined dynamically from VCS checkout' => sub {
    my $scheduled_products_mock = Test::MockModule->new('OpenQA::Schema::Result::ScheduledProducts', no_auto => 1);
    my $fake_git = 'Mocked git';
    $scheduled_products_mock->redefine(checkout_distri => sub { $fake_git });
    #TODO: {
    #    local $TODO = 'not implemented';
    #    my $res = schedule_iso({%iso});
    #    is($res->json->{count}, 2, 'Amount of jobs scheduled as defined in the evaluated schedule');
    #    is_deeply($res->json->{failed_job_info}, [], 'no failed jobs');
    #    is($jobs->find($res->json->{ids}->[0])->settings_hash->{DISTRI_SOURCE}, $distri, 'original distri URL is preserved');
    #    $res = schedule_iso({%iso, DISTRI => $distri . '#my_distri'});
    #    is_deeply($res->json->{failed_job_info}, [], 'no failed jobs for custom distri name');
    #    is($jobs->find($res->json->{ids}->[0])->settings_hash->{DISTRI}, 'my_distri', 'distri customized');
    #};
    $scheduled_products_mock->unmock('checkout_distri');
    my $res;
    combined_like sub { $res = schedule_iso({%iso, DISTRI => 'invalid://unknown/protocol'}, 400); }, qr/fatal: Unable to find remote helper/, 'error message returned from git';
    like($res->json->{error}, qr/Error on distri handling/, 'Error trying to checkout from unknown git protocol');
};

subtest 'async flag is unaffected by remote distri parameter' => sub {
    my $res = schedule_iso(\%iso, 200, {async => 1});
};

done_testing();
