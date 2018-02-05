#!/usr/bin/env perl -w
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
# with this program; if not, see <http://www.gnu.org/licenses/>.

use strict;
use warnings;
use FindBin;
use lib ("$FindBin::Bin/lib", "../lib", "lib");
use Test::More;
use OpenQA::Client;
use Test::Mojo;
use OpenQA::WebAPI;
use Mojo::File qw(tempfile tempdir path);

use OpenQA::Test::Case;

require OpenQA::Schema::Result::Jobs;

OpenQA::Test::Case->new->init_data;

# allow up to 200MB - videos mostly
$ENV{MOJO_MAX_MESSAGE_SIZE} = 207741824;

my $t = Test::Mojo->new('OpenQA::WebAPI');

# XXX: Test::Mojo loses it's app when setting a new ua
# https://github.com/kraih/mojo/issues/598
my $app = $t->app;
$t->ua(
    OpenQA::Client->new(apikey => 'PERCIVALKEY02', apisecret => 'PERCIVALSECRET02')->ioloop(Mojo::IOLoop->singleton));
$t->app($app);
my $base_url = $t->ua->server->url->to_string;

$t->app->schema->resultset('Jobs')->find(99963)->update({state              => 'running'});
$t->app->schema->resultset('Jobs')->find(99963)->update({assigned_worker_id => 2});

subtest 'OpenQA::Client' => sub {
    use OpenQA::Client;

    use File::Temp;
    my ($fh, $filename) = File::Temp::tempfile(UNLINK => 1);
    seek($fh, 20 * 1024 * 1024, 0);    # create 200MB quick
    syswrite($fh, "X");
    close($fh);
    my $sum = OpenQA::File::_file_digest($filename);

    my $client = OpenQA::Client->new(apikey => 'PERCIVALKEY02', apisecret => 'PERCIVALSECRET02')
      ->ioloop(Mojo::IOLoop->singleton);
    $client->base_url($base_url);

    my $app = $t->app;
    $t->ua($client);

    $t->app($app);

    my $chunkdir = 't/data/openqa/share/factory/tmp/public/hdd_image2.qcow2.CHUNKS/';
    my $rp       = "t/data/openqa/share/factory/hdd/hdd_image2.qcow2";

    local $@;
    eval { $t->ua->upload->asset(99963 => {file => $filename, name => 'hdd_image2.qcow2',}); };

    ok !$@, 'No upload errors' or die explain $@;

    path($chunkdir)->remove_tree;

    ok(!-d $chunkdir, 'Chunk directory should not exist anymore');

    ok(-e $rp, 'Asset exists after upload');

    is $sum, OpenQA::File::_file_digest($rp), 'cksum match!';
    my $ret = $t->get_ok('/api/v1/assets/hdd/hdd_image2.qcow2')->status_is(200);
    is($ret->tx->res->json->{name}, 'hdd_image2.qcow2');

};

done_testing();
1;
