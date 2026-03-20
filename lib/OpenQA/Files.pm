# Copyright 2018 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Files;
use Mojo::Base 'OpenQA::Parser::Results', -signatures;

use Digest::SHA 'sha1_base64';
use Mojo::File 'path';
use OpenQA::File;
use Mojo::Exception;

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

sub write_chunks ($class, $chunk_path, $file) {
    return Mojo::File->new($chunk_path)->list_tree()->sort->each(
        sub {
            my $chunk = OpenQA::File->deserialize($_->slurp);
            $chunk->decode_content;    # Decode content before writing it
            $chunk->write_content($file);
        });
}

sub write_verify_chunks ($class, $chunk_path, $file) {
    $class->write_chunks($chunk_path => $file);
    return $class->verify_chunks($chunk_path => $file);
}

sub spew ($self, $dir) {
    return $self->each(
        sub {
            $_->prepare;    # Prepare your data first before serializing
            Mojo::File->new($dir, $_->index)->spew($_->serialize);
        });
}

sub verify_chunks ($class, $chunk_path, $verify_file) {
    my $sum;
    for (Mojo::File->new($chunk_path)->list_tree()->each) {
        my $chunk = OpenQA::File->deserialize($_->slurp);

        $chunk->decode_content;
        $sum = $chunk->total_cksum if !$sum;
        return Mojo::Exception->new(
            'Chunk: ' . $chunk->id() . ' differs in total checksum, expected $sum given ' . $chunk->total_cksum)
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
