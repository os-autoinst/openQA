# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Files;
use Mojo::Base 'OpenQA::Parser::Results', -signatures;

use Digest::SHA 'sha1_base64';
use Mojo::File 'path';
use OpenQA::File;

sub join ($self) {
    return join '', map { $_->read } $self->each;
}

sub serialize ($self) {
    $self->join();    # Be sure content was read
    return map { $_->serialize } $self->each;
}

sub deserialize ($self, @args) {
    return $self->new(map { OpenQA::File->deserialize($_) } @args);
}

sub write ($self, $path) { path($path)->spew($self->join()) }

sub generate_sum ($self) { sha1_base64($self->join()) }

sub is_sum ($self, $sum) { $self->generate_sum eq $sum }

sub prepare ($self) {
    return $self->each(sub ($file, $i) { $file->prepare });
}

1;
