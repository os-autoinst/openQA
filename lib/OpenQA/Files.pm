# Copyright 2018 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Files;
use Mojo::Base 'OpenQA::Parser::Results';

use Digest::SHA 'sha1_base64';
use Mojo::File 'path';
use OpenQA::File;
use Mojo::Exception;

sub join {
    my $self = shift;
    return join '', map { $_->read } $self->each;
}

sub serialize {
    my $self = shift;
    $self->join();    # Be sure content was read
    return map { $_->serialize } $self->each;
}

sub deserialize {
    my $self = shift;
    return $self->new(map { OpenQA::File->deserialize($_) } @_);
}

sub write { Mojo::File->new(pop())->spurt(shift()->join()) }

sub generate_sum { sha1_base64(shift()->join()) }

sub is_sum { shift->generate_sum eq shift }

sub prepare {
    my $self = shift;
    return $self->each(sub { $_->prepare });
}

sub write_chunks {
    my ($class, $chunk_path, $file) = @_;

    return Mojo::File->new($chunk_path)->list_tree()->sort->each(
        sub {
            my $chunk = OpenQA::File->deserialize($_->slurp);
            $chunk->decode_content;    # Decode content before writing it
            $chunk->write_content($file);
        });
}

sub write_verify_chunks {
    my ($class, $chunk_path, $file) = @_;
    $class->write_chunks($chunk_path => $file);
    return $class->verify_chunks($chunk_path => $file);
}

sub spurt {
    my ($self, $dir) = @_;
    return $self->each(
        sub {
            $_->prepare;    # Prepare your data first before serializing
            Mojo::File->new($dir, $_->index)->spurt($_->serialize);
        });
}

sub verify_chunks {
    my ($class, $chunk_path, $verify_file) = @_;

    my $sum;
    for (Mojo::File->new($chunk_path)->list_tree()->each) {
        my $chunk = OpenQA::File->deserialize($_->slurp);

        $chunk->decode_content;
        $sum = $chunk->total_cksum if !$sum;
        return Mojo::Exception->new(
            "Chunk: " . $chunk->id() . " differs in total checksum, expected $sum given " . $chunk->total_cksum)
          if $sum ne $chunk->total_cksum;
        return Mojo::Exception->new("Can't verify written data from chunk")
          unless $chunk->verify_content($verify_file);
    }

    my $final_sum = OpenQA::File->file_digest(Mojo::File->new($verify_file)->to_string);
    return Mojo::Exception->new("Total checksum failed: expected $sum, computed " . $final_sum)
      if $sum ne $final_sum;
    return undef;
}

1;
