# Copyright 2018 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Client::Upload;
use Mojo::Base 'OpenQA::Client::Handler', -signatures;

use OpenQA::File;
use Carp qw(croak);
use Mojo::Asset::Memory;
use Mojo::File qw(path);

sub _upload_asset_fail ($self, $uri, $form) {
    $form->{state} = 'fail';
    return $self->client->start($self->_build_post("$uri/upload_state" => $form));
}

sub asset ($self, $job_id, $opts) {
    croak 'You need to specify a base_url' unless $self->client->base_url;
    croak 'Options must be a HASH ref' unless ref $opts eq 'HASH';
    croak 'Need a file to upload in the options!' unless $opts->{file};

    my $uri = "jobs/$job_id";
    $opts->{asset} //= 'public';
    my $file_name = $opts->{name} || path($opts->{file})->basename;

    # Worker and WebUI are on the same host (much faster)
    if ($opts->{local} && $self->is_local) {
        $self->emit('upload_local.prepare');
        my $tx = $self->client->start(
            $self->_build_post(
                "$uri/artefact" => {
                    file => {filename => $file_name, content => ''},
                    asset => $opts->{asset},
                    local => "$opts->{file}"
                }));
        $self->emit('upload_local.response', $tx, 0);
        return undef;
    }

    my $chunk_size = $opts->{chunk_size} // 1000000;
    my $parts = OpenQA::File->new(file => Mojo::File->new($opts->{file}))->split($chunk_size);
    $self->emit('upload_chunk.prepare', $parts);

    $self->once('upload_chunk.error',
        sub { $self->_upload_asset_fail($uri => {filename => $file_name, scope => $opts->{asset}}) });

    # Each chunk of the file should get the full number of retry attempts
    my $max_retries = $opts->{retries} // 10;
    my ($failed, $final_error);
    for my $part ($parts->each) {
        last if $failed;
        $self->emit('upload_chunk.start', $part);
        $part->prepare();

        my $retries = $max_retries;
        my $done;
        do {
            $retries-- if $retries > 0;
            my $tx;
            eval {
                my $form = {
                    file => {filename => $file_name, file => Mojo::Asset::Memory->new->add_chunk($part->serialize)},
                    asset => $opts->{asset},
                };
                $tx = $self->client->start($self->_build_post("$uri/artefact" => $form));
                $self->emit('upload_chunk.response', $tx, $retries);

                if ($tx) {
                    my $json = $tx->res->json;
                    $done = 1 if $json && $json->{status} && $json->{status} eq 'ok';
                }
            };
            if (my $error = $@) {
                $self->emit('upload_chunk.request_err', $tx, $error);
                $final_error = $error;
            }

            unless ($done) {
                $self->emit('upload_chunk.fail', $tx, $part, $max_retries - $retries, $max_retries);
                $final_error ||= $tx if $retries == 0;
            }
        } until ($retries == 0 || $done);

        $failed = 1 if $retries == 0 && !$done;

        $part->content(\undef);
        $self->emit('upload_chunk.finish', $part);
    }

    $self->emit('upload_chunk.error', $final_error) if $failed;

    return;
}

1;
