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

package OpenQA::File;
use Mojo::Base 'OpenQA::Parser::Result';
use OpenQA::Parser::Results;
use Exporter 'import';
use Carp 'croak';
use Digest::SHA 'sha1_base64';
use Fcntl 'SEEK_SET';
#use Mojo::JSON qw(encode_json decode_json);
#use Sereal qw( encode_sereal decode_sereal ); # XXX: This would speed up notably

has file => sub { Mojo::File->new() };
has [qw(start end index cksum total content total_cksum)];

our @EXPORT_OK = ('path');

sub new {
    my $self = shift->SUPER::new(@_);
    croak 'You must specify a file!'          unless defined $self->file();
    $self->file(Mojo::File->new($self->file)) unless ref $self->file eq 'Mojo::File';
    $self->index(1)                           unless defined $self->index;
    $self->start(0)                           unless defined $self->start;
    $self->total(1)                           unless defined $self->total;
    $self->end($self->size)                   unless defined $self->end;
    $self;
}

sub size        { -s shift()->file() }
sub path        { __PACKAGE__->new(file => Mojo::File->new(@_)) }
sub child       { __PACKAGE__->new(file => shift->file->child(@_)) }
sub slurp       { shift()->file()->slurp() }
sub _chunk_size { int($_[0] / $_[1]) + (($_[0] % $_[1]) ? 1 : 0) }
sub is_last     { !!($_[0]->total == $_[0]->index()) }

# sub serialize   { encode_sereal(shift->to_el) }
# sub deserialize { shift()->new(OpenQA::Parser::Result::_restore_el(decode_sereal(shift))) }
#sub serialize   { encode_json(shift->to_el) }
#sub deserialize { shift()->new(OpenQA::Parser::Result::_restore_el(decode_json(shift))) }

sub write_content {
    my $self = shift;
    $self->_write_content(pop);
    $self;
}

sub verify_content {
    my $self = shift;
    return !!($self->cksum eq $self->_sum($self->_seek_content(pop)));
}

sub prepare {
    $_[0]->generate_sum;
    $_[0]->encode_content;
}

sub _chunk {
    my ($self, $index, $n_chunks, $chunk_size, $residual, $total_cksum) = @_;

    my $seek_start = ($index - 1) * $chunk_size;
    my $prev       = ($index - 2) * $chunk_size + $chunk_size;
    my ($chunk_start, $chunk_end)
      = $index == $n_chunks
      && $residual ?
      ($prev, $prev + $residual)
      : ($seek_start, $seek_start + $chunk_size);

    return $self->new(
        index       => $index,
        start       => $chunk_start,
        end         => $chunk_end,
        total       => $n_chunks,
        total_cksum => $total_cksum,
        file        => $self->file,
    );
}

sub get_piece {
    my ($self, $index, $chunk_size) = @_;
    croak 'You need to define a file' unless defined $self->file();
    $self->file(Mojo::File->new($self->file())) unless ref $self->file eq 'Mojo::File';

    my $total_cksum = OpenQA::File::_file_digest($self->file->to_string);
    my $residual    = $self->size() % $chunk_size;
    my $n_chunks    = _chunk_size($self->size(), $chunk_size);

    return $self->_chunk($index, $n_chunks, $chunk_size, $residual, $total_cksum);
}

sub split {
    my ($self, $chunk_size) = @_;
    $chunk_size //= 10000000;
    croak 'You need to define a file' unless defined $self->file();
    $self->file(Mojo::File->new($self->file())) unless ref $self->file eq 'Mojo::File';

    my $total_cksum = OpenQA::File::_file_digest($self->file->to_string);

    my $residual = $self->size() % $chunk_size;
    my $n_chunks = _chunk_size($self->size(), $chunk_size);
    my $files    = OpenQA::Files->new();

    for (my $i = 1; $i <= $n_chunks; $i++) {
        #$piece->generate_sum; # XXX: Generate sha here and ditch content?
        $files->add($self->_chunk($i, $n_chunks, $chunk_size, $residual, $total_cksum));
    }

    return $files;
}

sub _file_digest {
    my $file   = pop;
    my $digest = Digest::SHA->new('sha256');
    $digest->addfile($file);
    return $digest->b64digest;
}

sub read {
    my $self = shift;
    return $self->content() if $self->content();
    $self->content($self->_seek_content(${$self->file}));
    return $self->content;
}

sub _seek_content {
    my ($self, $file_name) = @_;
    croak 'No start point is defined' unless defined $self->start();
    croak 'No end point is defined'   unless defined $self->end();

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
    croak 'No end point is defined'   unless defined $self->end();

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
    $self->read() unless $self->content();
    $self->cksum($self->_sum($self->content()));
    $self->cksum;
}

sub encode_content { $_[0]->content(unpack 'H*', $_[0]->content()) }
sub decode_content { $_[0]->content(pack 'H*',   $_[0]->content()) }

sub _sum { sha1_base64(pop) }    # Weaker for chunks

package OpenQA::Files {
    use Mojo::Base 'OpenQA::Parser::Results';
    use Digest::SHA 'sha1_base64';
    use Mojo::File 'path';
    use OpenQA::File;
    use Mojo::Exception;

    sub join {
        my $content;
        shift()->each(
            sub {
                $content .= $_->read();
            });
        $content;
    }

    sub serialize {
        my $self = shift;
        $self->join();    # Be sure content was read
        my @res;
        $self->each(
            sub {
                push @res, $_->serialize();
            });
        @res;
    }

    sub deserialize {
        my $self = shift;
        return $self->new(map { OpenQA::File->deserialize($_) } @_);
    }

    sub write        { Mojo::File->new(pop())->spurt(shift()->join()) }
    sub generate_sum { sha1_base64(shift()->join()) }
    sub is_sum       { shift->generate_sum eq shift }
    sub prepare {
        shift()->each(sub { $_->prepare });
    }
    sub write_chunks {
        my $file       = pop();
        my $chunk_path = pop();
        Mojo::File->new($chunk_path)->list_tree()->sort->each(
            sub {
                my $chunk = OpenQA::File->deserialize($_->slurp);
                $chunk->decode_content;    # Decode content before writing it
                $chunk->write_content($file);
            });
    }

    sub write_verify_chunks {
        my $file       = pop();
        my $chunk_path = pop();
        write_chunks($chunk_path => $file);
        return verify_chunks($chunk_path => $file);
    }

    sub spurt {
        my $dir = pop();
        shift->each(
            sub {
                $_->prepare;    # Prepare your data first before serializing
                Mojo::File->new($dir, $_->index)->spurt($_->serialize);
            });
    }

    sub verify_chunks {
        my $verify_file = pop();
        my $chunk_path  = pop();

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

        my $final_sum = OpenQA::File::_file_digest(Mojo::File->new($verify_file)->to_string);
        return Mojo::Exception->new("Total checksum failed: expected $sum, computed " . $final_sum)
          if $sum ne $final_sum;
        return;
    }
}

1;
