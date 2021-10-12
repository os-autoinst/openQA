# Copyright 2018 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Client::Upload;
use Mojo::Base 'OpenQA::Client::Handler';

use OpenQA::File;
use Carp qw(croak);
use Mojo::Asset::Memory;
use Mojo::File qw(path);

has max_retrials => 5;

sub _upload_asset_fail {
    my ($self, $uri, $form) = @_;
    $form->{state} = 'fail';
    return $self->client->start($self->_build_post("$uri/upload_state" => $form));
}

sub asset {
    my ($self, $job_id, $opts) = @_;
    croak 'You need to specify a base_url' unless $self->client->base_url;
    croak 'Options must be a HASH ref' unless ref $opts eq 'HASH';
    croak 'Need a file to upload in the options!' unless $opts->{file};

    my $uri = "jobs/$job_id";
    $opts->{asset} //= 'public';
    my $file_name = (!$opts->{name}) ? path($opts->{file})->basename : $opts->{name};

    # Worker and WebUI are on the same host (much faster)
    if ($opts->{local} && $self->is_local) {
        $self->emit('upload_local.prepare');
        my $res = $self->client->start(
            $self->_build_post(
                "$uri/artefact" => {
                    file => {filename => $file_name, content => ''},
                    asset => $opts->{asset},
                    local => "$opts->{file}"
                }));
        $self->emit('upload_local.response' => $res);
        return undef;
    }

    my $chunk_size = $opts->{chunk_size} // 1000000;
    my $pieces = OpenQA::File->new(file => Mojo::File->new($opts->{file}))->split($chunk_size);
    $self->emit('upload_chunk.prepare' => $pieces);

    $self->once('upload_chunk.error' =>
          sub { $self->_upload_asset_fail($uri => {filename => $file_name, scope => $opts->{asset}}) });
    my $failed;
    my $e;

    for ($pieces->each) {
        last if $failed;
        $self->emit('upload_chunk.start' => $_);
        $_->prepare();

        my $trial = $self->max_retrials;
        my $res;
        my $done = 0;
        do {
            local $@;
            eval {
                $res = $self->client->start(
                    $self->_build_post(
                        "$uri/artefact" => {
                            file =>
                              {filename => $file_name, file => Mojo::Asset::Memory->new->add_chunk($_->serialize)},
                            asset => $opts->{asset},
                        }));
                $self->emit('upload_chunk.response' => $res);
                $done = 1
                  if $res && $res->res->json && exists $res->res->json->{status} && $res->res->json->{status} eq 'ok';
            };
            $self->emit('upload_chunk.fail' => $res => $_) if $done == 0;

            $trial-- if $trial > 0;
            $self->emit('upload_chunk.request_err' => $res => $@) if $@;
            $e = $@ || $res if $trial == 0 && $done == 0;
        } until ($trial == 0 || $done);

        $failed++ if $trial == 0 && $done == 0;

        $_->content(\undef);

        $self->emit('upload_chunk.finish' => $_);
    }

    $self->emit('upload_chunk.error' => $e) if $failed;

    return;
}

1;
