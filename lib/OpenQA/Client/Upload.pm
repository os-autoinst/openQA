# Copyright (C) 2018 SUSE Linux Products GmbH
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

package OpenQA::Client::Upload;
use Mojo::Base 'OpenQA::Client::Handler';

use Mojo::Exception;
use OpenQA::File;
use Carp 'croak';
use Mojo::Asset::Memory;

has max_retrials => 5;

sub _upload_asset_fail {
    my ($self, $uri, $form) = @_;
    $form->{state} = 'fail';
    return $self->client->start($self->_build_post("$uri/upload_state" => $form));
}

sub asset {
    my ($self, $job_id, $opts) = @_;
    croak 'You need to specify a base_url'                           unless $self->client->base_url;
    $self->client->base_url(Mojo::URL->new($self->client->base_url)) unless ref $self->client->base_url eq 'Mojo::URL';
    croak 'Options must be a HASH ref'                               unless ref $opts eq 'HASH';
    croak 'Need a file to upload in the options!'                    unless $opts->{file};

    my $uri = "api/v1/jobs/$job_id";
    $opts->{asset} //= 'public';
    my $file_name  = (!$opts->{name}) ? path($opts->{file})->basename : $opts->{name};
    my $chunk_size = $opts->{chunk_size} // 1000000;
    my $pieces     = OpenQA::File->new(file => Mojo::File->new($opts->{file}))->split($chunk_size);

    my $failed;

    for ($pieces->each) {
        $_->prepare();
        last if $failed;

        my $trial = $self->max_retrials;
        my $res;
        my $done = 0;

        do {
            my $file_opts = {
                file  => {filename => $file_name, file => Mojo::Asset::Memory->new->add_chunk($_->serialize)},
                asset => $opts->{asset}};
            my $post = $self->_build_post("$uri/artefact" => $file_opts);

            $res   = $self->client->start($post);
            $done  = 1 if $res && $res->res->json && $res->res->json->{status} && $res->res->json->{status} eq 'ok';
            $trial = 0 if (!$res->res->is_server_error && $res->error);
            $trial-- if $trial > 0;
            die Mojo::Exception->new($res->res) if $trial == 0 && $done == 0;
        } until ($trial == 0 || $done);

        $failed++ if $trial == 0 && $done == 0;

        $_->content(\undef);
    }

    $self->_upload_asset_fail($uri => {filename => $file_name, scope => $opts->{asset}}) if $failed;

    return;
}

1;
