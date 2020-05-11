#!/usr/bin/env perl
# Copyright (C) 2018-2020 SUSE LLC
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

use Test::Most;

use FindBin;
use lib ("$FindBin::Bin/lib", "../lib", "lib");
use File::Temp;
use OpenQA::Client;
use Test::Mojo;
use OpenQA::WebAPI;
use Mojo::File qw(tempfile path);
use OpenQA::Client;
use OpenQA::Events;
use OpenQA::Test::Case;

require OpenQA::Schema::Result::Jobs;

OpenQA::Test::Case->new->init_data;
my $chunk_size = 10000000;

# allow up to 200MB - videos mostly
$ENV{MOJO_MAX_MESSAGE_SIZE} = 207741824;

my $t = Test::Mojo->new('OpenQA::WebAPI');

OpenQA::Events->singleton->on(
    'chunk_upload.end' => sub {
        Devel::Cover::report() if Devel::Cover->can('report');
    });

# XXX: Test::Mojo loses it's app when setting a new ua
# https://github.com/kraih/mojo/issues/598
my $app = $t->app;

sub new_client {
    OpenQA::Client->new(apikey => 'PERCIVALKEY02', apisecret => 'PERCIVALSECRET02')->ioloop(Mojo::IOLoop->singleton);
}

my $client = new_client;
$t->ua($client);
$t->app($app);
my $base_url = $t->ua->server->url->to_string;
$client->base_url($base_url);

$t->app->schema->resultset('Jobs')->find(99963)->update({state              => 'running'});
$t->app->schema->resultset('Jobs')->find(99963)->update({assigned_worker_id => 2});
my ($fh, $filename) = File::Temp::tempfile(UNLINK => 1);
seek($fh, 20 * 1024 * 1024, 0);    # create 200MB quick
syswrite($fh, "X");
close($fh);
my $sum = OpenQA::File->file_digest($filename);

subtest 'upload public assets' => sub {
    my $chunkdir = 't/data/openqa/share/factory/tmp/public/hdd_image2.qcow2.CHUNKS/';
    my $rp       = "t/data/openqa/share/factory/hdd/hdd_image2.qcow2";

    local $@;
    eval {
        $t->ua->upload->asset(99963 => {chunk_size => $chunk_size, file => $filename, name => 'hdd_image2.qcow2',});
    };
    ok !$@, 'No upload errors' or die explain $@;
    path($chunkdir)->remove_tree;
    ok !-d $chunkdir, 'Chunk directory should not exist anymore';
    ok -e $rp,        'Asset exists after upload';
    is $sum, OpenQA::File->file_digest($rp), 'checksum matches for public asset';
    $t->get_ok('/api/v1/assets/hdd/hdd_image2.qcow2')->status_is(200);
    is $t->tx->res->json->{name}, 'hdd_image2.qcow2', 'name is expected for public asset';
};

subtest 'upload private assets' => sub {
    my $chunkdir = 't/data/openqa/share/factory/tmp/private/00099963-hdd_image3.qcow2.CHUNKS/';
    my $rp       = "t/data/openqa/share/factory/hdd/00099963-hdd_image3.qcow2";

    local $@;
    eval {
        $t->ua->upload->asset(
            99963 => {chunk_size => $chunk_size, file => $filename, name => 'hdd_image3.qcow2', asset => 'private'});
    };
    ok !$@, 'No upload errors' or die explain $@;
    ok !-d $chunkdir, 'Chunk directory should not exist anymore';
    ok -e $rp,        'Asset exists after upload';
    is $sum, OpenQA::File->file_digest($rp), 'checksum matches for private asset';
    $t->get_ok('/api/v1/assets/hdd/00099963-hdd_image3.qcow2')->status_is(200);
    is $t->tx->res->json->{name}, '00099963-hdd_image3.qcow2', 'name is expected for private asset';
};

subtest 'upload other assets' => sub {
    my $chunkdir = 't/data/openqa/share/factory/tmp/other/00099963-hdd_image3.xml.CHUNKS/';
    my $rp       = "t/data/openqa/share/factory/other/00099963-hdd_image3.xml";

    $t->ua->upload->once(
        'upload_chunk.response' => sub {
            ok(-d $chunkdir, 'Chunk directory exists');
        });

    local $@;
    eval {
        $t->ua->upload->asset(
            99963 => {chunk_size => $chunk_size, file => $filename, name => 'hdd_image3.xml', asset => 'other'});
    };
    ok !$@, 'No upload errors' or die explain $@;
    ok !-d $chunkdir, 'Chunk directory should not exist anymore';
    ok -e $rp,        'Asset exists after upload';
    is $sum, OpenQA::File->file_digest($rp), 'checksum matches for other asset';
    $t->get_ok('/api/v1/assets/other/00099963-hdd_image3.xml')->status_is(200);
    is $t->tx->res->json->{name}, '00099963-hdd_image3.xml', 'name is expected for other asset';
};

subtest 'upload retrials' => sub {
    my $chunkdir = 't/data/openqa/share/factory/tmp/other/00099963-hdd_image4.xml.CHUNKS/';
    my $rp       = "t/data/openqa/share/factory/other/00099963-hdd_image4.xml";

    # Sabotage!
    my $fired;
    my $fail_chunk;
    my $responses;
    $t->ua->upload->once(
        'upload_chunk.response' => sub { my ($self, $response) = @_; delete $response->res->json->{status}; $fired++; }
    );
    $t->ua->upload->on('upload_chunk.fail'         => sub { $fail_chunk++ });
    $t->ua->upload->on('upload_chunk.response'     => sub { $responses++; });
    $t->ua->upload->on('upload_chunk.request_fail' => sub { use Data::Dump 'pp'; diag pp(@_) });

    local $@;
    eval {
        $t->ua->upload->asset(
            99963 => {chunk_size => $chunk_size, file => $filename, name => 'hdd_image4.xml', asset => 'other'});
    };
    is $fail_chunk, 1, 'One chunk failed uploading, but we recovered' or diag explain "\$fail_chunk: $fail_chunk";
    ok !$@, 'No upload errors';
    is $responses, OpenQA::File::_chunk_size(-s $filename, $chunk_size) + 1, 'responses as expected';
    ok !-d $chunkdir, 'Chunk directory should not exist anymore';
    ok -e $rp,        'Asset exists after upload';
    is $sum, OpenQA::File->file_digest($rp), 'checksum matches on uploaded file';
    $t->get_ok('/api/v1/assets/other/00099963-hdd_image4.xml')->status_is(200);
    is $t->tx->res->json->{name}, '00099963-hdd_image4.xml', 'uploaded file is correct one';
};

subtest 'upload failures' => sub {
    my $chunkdir = 't/data/openqa/share/factory/tmp/other/00099963-hdd_image5.xml.CHUNKS/';
    my $rp       = "t/data/openqa/share/factory/other/00099963-hdd_image5.xml";

    # Moar Sabotage!
    my $fired;
    my $fail_chunk;
    my $errored;
    $t->ua->upload->on('upload_chunk.response' =>
          sub { my ($self, $response) = @_; $response->res->json->{status} = 'foobar'; $fired++; });
    $t->ua->upload->on('upload_chunk.fail' => sub { $fail_chunk++ });
    $t->ua->upload->on(
        'upload_chunk.error' => sub {
            $errored++;
            is(pop()->res->json->{status}, 'foobar', 'Error message status is correct');
        });

    local $@;
    eval {
        $t->ua->upload->asset(
            99963 => {chunk_size => $chunk_size, file => $filename, name => 'hdd_image5.xml', asset => 'other'});
    };
    is $fail_chunk, 5, 'All chunks failed, no recovery on upload failures';
    is $errored,    1, 'Upload errors';
    ok !$@, 'No function errors on upload failures' or die diag $@;
    ok !-d $chunkdir, 'Chunk directory should not exist anymore';
    ok !-e $rp,       'Asset does not exists after upload on upload failures';
    $t->get_ok('/api/v1/assets/other/00099963-hdd_image5.xml')->status_is(404);
};

subtest 'upload internal errors' => sub {
    my $client = new_client;
    $client->base_url($base_url);
    $t->ua($client);
    $t->app($app);

    my $chunkdir = 't/data/openqa/share/factory/tmp/other/00099963-hdd_image6.xml.CHUNKS/';
    my $rp       = "t/data/openqa/share/factory/other/00099963-hdd_image6.xml";

    # Moar Sabotage!
    my $fail_chunk;
    my $e;
    $t->ua->upload->on('upload_chunk.response'    => sub { die("Subdly") });
    $t->ua->upload->on('upload_chunk.request_err' => sub { $fail_chunk++; $e = pop(); });

    local $@;
    eval {
        $t->ua->upload->asset(
            99963 => {chunk_size => $chunk_size, file => $filename, name => 'hdd_image6.xml', asset => 'other'});
    };
    is $fail_chunk, 5,          'All chunks failed, no recovery on internal errors';
    like $e,        qr/Subdly/, 'Internal error seen';
    ok !$@, 'No function errors on internal errors' or die diag $@;
    ok !-d $chunkdir, 'Chunk directory should not exist anymore';
    ok !-e $rp,       'Asset does not exists after upload on internal errors';
    $t->get_ok('/api/v1/assets/other/00099963-hdd_image6.xml')->status_is(404);
};

done_testing();
