#!/usr/bin/env perl
# Copyright 2018-2020 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;

use FindBin;
use lib "$FindBin::Bin/lib", "$FindBin::Bin/../external/os-autoinst-common/lib";
use Test::Mojo;
use Mojo::File qw(tempfile path);
use OpenQA::Events;
use OpenQA::Test::Case;
use OpenQA::Test::Client 'client';
use OpenQA::Test::TimeLimit '80';

plan skip_all => 'set HEAVY=1 to execute (takes longer)' unless $ENV{HEAVY};

OpenQA::Test::Case->new->init_data(fixtures_glob => '01-jobs.pl 02-workers.pl 03-users.pl');
my $chunk_size = 10000000;

# allow up to 200MB - videos mostly
$ENV{MOJO_MAX_MESSAGE_SIZE} = 207741824;

OpenQA::Events->singleton->on(
    'chunk_upload.end' => sub {
        Devel::Cover::report() if Devel::Cover->can('report');
    });

my @client_args = (apikey => 'PERCIVALKEY02', apisecret => 'PERCIVALSECRET02');
my $t = client(Test::Mojo->new('OpenQA::WebAPI'), @client_args);
my $client = $t->ua;
my $base_url = $client->server->url->to_string;
$client->base_url($base_url);
my $jobs = $t->app->schema->resultset('Jobs');
$jobs->find(99963)->update({state => 'running'});
$jobs->find(99963)->update({assigned_worker_id => 2});

my $tempfile = tempfile;
my $fh = $tempfile->open('>');
$fh->seek(20 * 1024 * 1024, 0);    # create 20MB quick
$fh->syswrite('X');
undef $fh;
my $filename = $tempfile->to_string;
my $sum = OpenQA::File->file_digest($filename);

subtest 'upload public assets' => sub {
    my $chunkdir = 't/data/openqa/share/factory/tmp/public/hdd_image2.qcow2.CHUNKS/';
    my $rp = "t/data/openqa/share/factory/hdd/hdd_image2.qcow2";

    eval { $t->ua->upload->asset(99963 => {chunk_size => $chunk_size, file => $filename, name => 'hdd_image2.qcow2'}); };
    ok !$@, 'No upload errors' or die explain $@;
    path($chunkdir)->remove_tree;
    ok !-d $chunkdir, 'Chunk directory should not exist anymore';
    ok -e $rp, 'Asset exists after upload';
    is $sum, OpenQA::File->file_digest($rp), 'checksum matches for public asset';
    $t->get_ok('/api/v1/assets/hdd/hdd_image2.qcow2')->status_is(200);
    $t->json_is('/name' => 'hdd_image2.qcow2', 'name is expected for public asset');
};

subtest 'upload public assets (local)' => sub {
    my $chunkdir = 't/data/openqa/share/factory/tmp/public/hdd_image5.qcow2.CHUNKS/';
    my $rp = "t/data/openqa/share/factory/hdd/hdd_image5.qcow2";

    eval {
        $t->ua->upload->asset(
            99963 => {chunk_size => $chunk_size, file => $filename, name => 'hdd_image5.qcow2', local => 1});
    };
    ok !$@, 'No upload errors' or die explain $@;
    path($chunkdir)->remove_tree;
    ok !-d $chunkdir, 'Chunk directory should not exist anymore';
    ok -e $rp, 'Asset exists after upload';
    is $sum, OpenQA::File->file_digest($rp), 'checksum matches for public asset';
    $t->get_ok('/api/v1/assets/hdd/hdd_image5.qcow2')->status_is(200);
    $t->json_is('/name' => 'hdd_image5.qcow2', 'name is expected for public asset');
};

subtest 'upload private assets' => sub {
    my $chunkdir = 't/data/openqa/share/factory/tmp/private/00099963-hdd_image3.qcow2.CHUNKS/';
    my $rp = "t/data/openqa/share/factory/hdd/00099963-hdd_image3.qcow2";

    my ($local_prepare, $chunk_prepare);
    my $local_prepare_cb = $t->ua->upload->on('upload_local.prepare' => sub { $local_prepare++ });
    my $chunk_prepare_cb = $t->ua->upload->on('upload_chunk.prepare' => sub { $chunk_prepare++ });
    eval {
        $t->ua->upload->asset(
            99963 => {chunk_size => $chunk_size, file => $filename, name => 'hdd_image3.qcow2', asset => 'private'});
    };
    ok !$@, 'No upload errors' or die explain $@;
    $t->ua->upload->unsubscribe('upload_local.prepare' => $local_prepare_cb);
    $t->ua->upload->unsubscribe('upload_chunl.prepare' => $chunk_prepare_cb);
    ok !$local_prepare, 'not uploaded via file copy';
    ok $chunk_prepare, 'uploaded via HTTP';

    ok !-d $chunkdir, 'Chunk directory should not exist anymore';
    ok -e $rp, 'Asset exists after upload';
    is $sum, OpenQA::File->file_digest($rp), 'checksum matches for private asset';
    $t->get_ok('/api/v1/assets/hdd/00099963-hdd_image3.qcow2')->status_is(200);
    $t->json_is('/name' => '00099963-hdd_image3.qcow2', 'name is expected for private asset');
};

subtest 'upload private assets (local)' => sub {
    my $chunkdir = 't/data/openqa/share/factory/tmp/private/00099963-hdd_image7.qcow2.CHUNKS/';
    my $rp = "t/data/openqa/share/factory/hdd/00099963-hdd_image7.qcow2";

    my ($local_prepare, $chunk_prepare);
    my $local_prepare_cb = $t->ua->upload->on('upload_local.prepare' => sub { $local_prepare++ });
    my $chunk_prepare_cb = $t->ua->upload->on('upload_chunk.prepare' => sub { $chunk_prepare++ });
    eval {
        $t->ua->upload->asset(
            99963 => {
                chunk_size => $chunk_size,
                file => $filename,
                name => 'hdd_image7.qcow2',
                asset => 'private',
                local => 1
            });
    };
    ok !$@, 'No upload errors' or die explain $@;
    $t->ua->upload->unsubscribe('upload_local.prepare' => $local_prepare_cb);
    $t->ua->upload->unsubscribe('upload_chunl.prepare' => $chunk_prepare_cb);
    ok $local_prepare, 'uploaded via file copy';
    ok !$chunk_prepare, 'not uploaded via HTTP';

    ok !-d $chunkdir, 'Chunk directory should not exist anymore';
    ok -e $rp, 'Asset exists after upload';
    is $sum, OpenQA::File->file_digest($rp), 'checksum matches for private asset';
    $t->get_ok('/api/v1/assets/hdd/00099963-hdd_image7.qcow2')->status_is(200);
    $t->json_is('/name' => '00099963-hdd_image7.qcow2', 'name is expected for private asset');
};

subtest 'upload other assets' => sub {
    my $chunkdir = 't/data/openqa/share/factory/tmp/other/00099963-hdd_image3.xml.CHUNKS/';
    my $rp = "t/data/openqa/share/factory/other/00099963-hdd_image3.xml";

    $t->ua->upload->once(
        'upload_chunk.response' => sub {
            ok(-d $chunkdir, 'Chunk directory exists');
        });

    eval {
        $t->ua->upload->asset(
            99963 => {chunk_size => $chunk_size, file => $filename, name => 'hdd_image3.xml', asset => 'other'});
    };
    ok !$@, 'No upload errors' or die explain $@;
    ok !-d $chunkdir, 'Chunk directory should not exist anymore';
    ok -e $rp, 'Asset exists after upload';
    is $sum, OpenQA::File->file_digest($rp), 'checksum matches for other asset';
    $t->get_ok('/api/v1/assets/other/00099963-hdd_image3.xml')->status_is(200);
    $t->json_is('/name' => '00099963-hdd_image3.xml', 'name is expected for other asset');
};

subtest 'upload retrials' => sub {
    my $chunkdir = 't/data/openqa/share/factory/tmp/other/00099963-hdd_image4.xml.CHUNKS/';
    my $rp = "t/data/openqa/share/factory/other/00099963-hdd_image4.xml";

    # Sabotage!
    my $fired;
    my $fail_chunk;
    my $responses;
    $t->ua->upload->once(
        'upload_chunk.response' => sub { my ($self, $response) = @_; delete $response->res->json->{status}; $fired++; }
    );
    $t->ua->upload->on('upload_chunk.fail' => sub { $fail_chunk++ });
    $t->ua->upload->on('upload_chunk.response' => sub { $responses++; });
    $t->ua->upload->on('upload_chunk.request_fail' => sub { use Data::Dump 'pp'; diag pp(@_) });

    eval {
        $t->ua->upload->asset(
            99963 => {chunk_size => $chunk_size, file => $filename, name => 'hdd_image4.xml', asset => 'other'});
    };
    ok !$@, 'No upload errors';
    is $fail_chunk, 1, 'One chunk failed uploading, but we recovered' or diag explain "\$fail_chunk: $fail_chunk";
    is $responses, OpenQA::File::_chunk_size(-s $filename, $chunk_size) + 1, 'responses as expected';
    ok !-d $chunkdir, 'Chunk directory should not exist anymore';
    ok -e $rp, 'Asset exists after upload';
    is $sum, OpenQA::File->file_digest($rp), 'checksum matches on uploaded file';
    $t->get_ok('/api/v1/assets/other/00099963-hdd_image4.xml')->status_is(200);
    $t->json_is('/name' => '00099963-hdd_image4.xml', 'uploaded file is correct one');
};

subtest 'upload failures' => sub {
    my $chunkdir = 't/data/openqa/share/factory/tmp/other/00099963-hdd_image5.xml.CHUNKS/';
    my $rp = "t/data/openqa/share/factory/other/00099963-hdd_image5.xml";

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

    eval {
        $t->ua->upload->asset(
            99963 => {chunk_size => $chunk_size, file => $filename, name => 'hdd_image5.xml', asset => 'other'});
    };
    ok !$@, 'No function errors on upload failures' or die diag $@;
    is $fail_chunk, 5, 'All chunks failed, no recovery on upload failures';
    is $errored, 1, 'Upload errors';
    ok !-d $chunkdir, 'Chunk directory should not exist anymore';
    ok !-e $rp, 'Asset does not exist after upload on upload failures';
    $t->get_ok('/api/v1/assets/other/00099963-hdd_image5.xml')->status_is(404);
};

subtest 'upload internal errors' => sub {
    my $client = client($t, @client_args)->ua;
    $client->base_url($base_url);

    my $chunkdir = 't/data/openqa/share/factory/tmp/other/00099963-hdd_image6.xml.CHUNKS/';
    my $rp = "t/data/openqa/share/factory/other/00099963-hdd_image6.xml";

    # Moar Sabotage!
    my $fail_chunk;
    my $e;
    $t->ua->upload->on('upload_chunk.response' => sub { die("Subdly") });
    $t->ua->upload->on('upload_chunk.request_err' => sub { $fail_chunk++; $e = pop(); });

    eval {
        $t->ua->upload->asset(
            99963 => {chunk_size => $chunk_size, file => $filename, name => 'hdd_image6.xml', asset => 'other'});
    };
    ok !$@, 'No function errors on internal errors' or die diag $@;
    is $fail_chunk, 5, 'All chunks failed, no recovery on internal errors';
    like $e, qr/Subdly/, 'Internal error seen';
    ok !-d $chunkdir, 'Chunk directory should not exist anymore';
    ok !-e $rp, 'Asset does not exist after upload on internal errors';
    $t->get_ok('/api/v1/assets/other/00099963-hdd_image6.xml')->status_is(404);
};

subtest 'detecting local webui' => sub {
    my $client = $t->ua->base_url('http://openqa-staging-1.qa.suse.de');
    ok !$client->upload->is_local, 'not a local webui';

    $client = $t->ua->base_url('http://localhost');
    ok $client->upload->is_local, 'local webui';

    $client = $t->ua->base_url('http://127.0.0.1');
    ok $client->upload->is_local, 'local webui';

    $client = $t->ua->base_url('http://127.0.0.1:3000');
    ok $client->upload->is_local, 'local webui';

    $client = $t->ua->base_url('http://[::1]');
    ok $client->upload->is_local, 'local webui';

    $client = $t->ua->base_url('http://[::1]:3000');
    ok $client->upload->is_local, 'local webui';

    $client = $t->ua->base_url('http://[2001:db8:85a3:8d3:1319:8a2e:370:7348]:3000');
    ok !$client->upload->is_local, 'not a local webui';

    $client = $t->ua->base_url('http://openqa-staging-1.qa.suse.de:3000');
    ok !$client->upload->is_local, 'not a local webui';
};

done_testing();
