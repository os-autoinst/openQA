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

has file => sub { Mojo::File->new() };
has [qw(start end index cksum total content total_cksum)];

our @EXPORT_OK = ('path');

sub size        { -s shift()->file() }
sub path        { __PACKAGE__->new(file => Mojo::File->new(@_)) }
sub child       { __PACKAGE__->new(file => shift->file->child(@_)) }
sub slurp       { shift()->file()->slurp() }
sub _chunk_size { int($_[0] / $_[1]) + (($_[0] % $_[1]) ? 1 : 0) }

sub write_content {
    my $self = shift;
    $self->_write_content(pop);
    $self;
}

sub verify_content {
    my $self = shift;
    return !!($self->cksum eq $self->_sum($self->_seek_content(pop)));
}

sub split {
    my ($self, $chunk_size) = @_;
    return OpenQA::Files->new($self) unless $chunk_size < $self->size;
    my $residual    = $self->size() % $chunk_size;
    my $total       = my $n_chunks = _chunk_size($self->size(), $chunk_size);
    my $files       = OpenQA::Files->new();
    my $total_cksum = $self->_sum($self->file->slurp);

    $n_chunks-- if $residual;

    for (my $i = 1; $i <= $n_chunks; $i++) {
        my $seek_start = ($i - 1) * $chunk_size;
        my $end        = $seek_start + $chunk_size;

        my $piece = $self->new(
            total       => $total,
            end         => $end,
            start       => $seek_start,
            index       => $i,
            file        => $self->file,
            total_cksum => $total_cksum,
        );
        #$piece->generate_sum; # XXX: Generate sha here?
        $files->add($piece);
    }
    return $files unless $residual;

    my $piece = $self->new(
        total_cksum => $total_cksum,
        total       => $total,
        end         => $files->last->end + $residual,
        start       => $files->last->end,
        index       => $total,
        file        => $self->file
    );
    #$piece->generate_sum;
    $files->add($piece);

    return $files;
}

sub read {
    my $self = shift;
    return $self->content() if $self->content();
    $self->content($self->_seek_content(${$self->file}));
    return $self->content;
}

sub _seek_content {
    my ($self, $file_name) = @_;
    CORE::open my $file, '<', $file_name or croak "Can't open file $file_name: $!";
    my $ret = my $content = '';
    sysseek($file, $self->start(), 1);
    $ret = $file->sysread($content, ($self->end() - $self->start()));
    croak "Can't read from file $file_name : $!" unless defined $ret;
    return $content;
}

sub _write_content {
    my ($self, $file_name) = @_;
    Mojo::File->new($file_name)->spurt('') unless -e $file_name;
    CORE::open my $file, '+<', $file_name or croak "Can't open file $file_name: $!";
    my $ret;
    sysseek($file, $self->start(), 1);
    $ret = $file->syswrite($self->content, ($self->end() - $self->start()));
    croak "Can't write to file $file_name : $!" unless defined $ret;
    return $ret;
}

sub generate_sum {
    my $self = shift;
    $self->read() if !$self->content();
    $self->cksum($self->_sum($self->content()));
    $self->cksum;
}

sub _sum { sha1_base64(pop) }

package OpenQA::Files {
    use Mojo::Base 'OpenQA::Parser::Results';
    use Digest::SHA 'sha1_base64';
    use Mojo::File 'path';
    use OpenQA::File;

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

    sub write        { path(pop())->spurt(shift()->join()) }
    sub generate_sum { sha1_base64(shift()->join()) }
    sub is_sum       { shift->generate_sum eq shift }
    sub prepare {
        shift()->each(sub { $_->generate_sum });
    }
    sub write_chunks {
        my $file       = pop();
        my $chunk_path = pop();
        Mojo::File->new($chunk_path)->list_tree()->each(
            sub {
                my $chunk = OpenQA::File->deserialize($_->slurp);
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
                $_->generate_sum;
                Mojo::File->new($dir, $_->index)->spurt($_->serialize);
            });
    }

    sub verify_chunks {
        my $verify_file = pop();
        my $chunk_path  = pop();

        my $sum;
        for (Mojo::File->new($chunk_path)->list_tree()->each) {
            my $chunk = OpenQA::File->deserialize($_->slurp);
            $sum = $chunk->total_cksum if !$sum;
            return 0 if $sum ne $chunk->total_cksum;
            return 0 if !$chunk->verify_content($verify_file);
        }

        return 0 if $sum ne sha1_base64(Mojo::File->new($verify_file)->slurp);

        return 1;
    }
}

1;
