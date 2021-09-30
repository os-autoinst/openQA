# Copyright 2018 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::File;
use Mojo::Base 'OpenQA::Parser::Result';

use OpenQA::Parser::Results;
use Carp 'croak';
use Digest::SHA 'sha1_base64';
use Fcntl 'SEEK_SET';
use OpenQA::Files;

has file => sub { Mojo::File->new };
has [qw(start end index cksum total content total_cksum)];

sub new {
    my $self = shift->SUPER::new(@_);
    croak 'You must specify a file!' unless defined $self->file();
    $self->file(Mojo::File->new($self->file)) unless ref $self->file eq 'Mojo::File';
    $self->index(1) unless defined $self->index;
    $self->start(0) unless defined $self->start;
    $self->total(1) unless defined $self->total;
    $self->end($self->size) unless defined $self->end;
    return $self;
}

sub size { -s shift->file }

sub _chunk_size { int($_[0] / $_[1]) + (($_[0] % $_[1]) ? 1 : 0) }

sub is_last { !!($_[0]->total == $_[0]->index()) }

sub write_content {
    my $self = shift;
    $self->_write_content(pop);
    return $self;
}

sub verify_content {
    my $self = shift;
    return !!($self->cksum eq $self->_sum($self->_seek_content(pop)));
}

sub prepare {
    my $self = shift;
    $self->generate_sum;
    $self->encode_content;
}

sub _chunk {
    my ($self, $index, $n_chunks, $chunk_size, $residual, $total_cksum) = @_;

    my $seek_start = ($index - 1) * $chunk_size;
    my $prev = ($index - 2) * $chunk_size + $chunk_size;
    my ($chunk_start, $chunk_end)
      = $index == $n_chunks && $residual
      ? ($prev, $prev + $residual)
      : ($seek_start, $seek_start + $chunk_size);

    return $self->new(
        index => $index,
        start => $chunk_start,
        end => $chunk_end,
        total => $n_chunks,
        total_cksum => $total_cksum,
        file => $self->file,
    );
}

sub get_piece {
    my ($self, $index, $chunk_size) = @_;
    croak 'You need to define a file' unless defined $self->file();
    $self->file(Mojo::File->new($self->file())) unless ref $self->file eq 'Mojo::File';

    my $total_cksum = OpenQA::File->file_digest($self->file->to_string);
    my $residual = $self->size() % $chunk_size;
    my $n_chunks = _chunk_size($self->size(), $chunk_size);

    return $self->_chunk($index, $n_chunks, $chunk_size, $residual, $total_cksum);
}

sub split {
    my ($self, $chunk_size) = @_;
    $chunk_size //= 10000000;
    croak 'You need to define a file' unless defined $self->file();
    $self->file(Mojo::File->new($self->file())) unless ref $self->file eq 'Mojo::File';

    my $total_cksum = OpenQA::File->file_digest($self->file->to_string);

    my $residual = $self->size() % $chunk_size;
    my $n_chunks = _chunk_size($self->size(), $chunk_size);
    my $files = OpenQA::Files->new();

    for (my $i = 1; $i <= $n_chunks; $i++) {
        #$piece->generate_sum; # XXX: Generate sha here and ditch content?
        $files->add($self->_chunk($i, $n_chunks, $chunk_size, $residual, $total_cksum));
    }

    return $files;
}

sub file_digest {
    my ($class, $file) = @_;
    my $digest = Digest::SHA->new('sha256');
    $digest->addfile($file);
    return $digest->b64digest;
}

sub read {
    my $self = shift;
    if (my $content = $self->content) { return $content }
    my $content = $self->_seek_content($self->file->to_string);
    $self->content($content);
    return $content;
}

sub _seek_content {
    my ($self, $file_name) = @_;

    croak 'No start point is defined' unless defined $self->start();
    croak 'No end point is defined' unless defined $self->end();

    CORE::open my $file, '<', $file_name or croak "Can't open file $file_name: $!";
    binmode($file);    # old Perl versions might need this
    my $ret = my $content = '';
    sysseek($file, $self->start(), SEEK_SET);
    $ret = $file->sysread($content, ($self->end() - $self->start()));
    croak "Can't read from file $file_name : $!" unless defined $ret;
    close($file);
    return $content;
}

sub _write_content {
    my ($self, $file_name) = @_;

    croak 'No start point is defined' unless defined $self->start();
    croak 'No end point is defined' unless defined $self->end();

    Mojo::File->new($file_name)->spurt('') unless -e $file_name;
    CORE::open my $file, '+<', $file_name or croak "Can't open file $file_name: $!";
    binmode($file);    # old Perl versions might need this
    my $ret;
    sysseek($file, $self->start(), SEEK_SET);
    $ret = $file->syswrite($self->content, ($self->end() - $self->start()));
    croak "Can't write to file $file_name : $!" unless defined $ret;
    close($file);

    return $ret;
}

sub generate_sum {
    my $self = shift;
    $self->read() unless $self->content;
    my $sum = $self->_sum($self->content);
    $self->cksum($sum);
    return $sum;
}

sub encode_content { $_[0]->content(unpack 'H*', $_[0]->content()) }
sub decode_content { $_[0]->content(pack 'H*', $_[0]->content()) }

sub _sum { sha1_base64(pop) }    # Weaker for chunks

1;
