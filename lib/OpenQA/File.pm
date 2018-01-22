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
use Mojo::Base -base;
use OpenQA::Parser::Results;
use Exporter 'import';
use Carp 'croak';
has 'file' => sub { Mojo::File->new() };
has [qw(start end index cksum total)];

our @EXPORT_OK = ('path');

sub size        { -s shift()->file() }
sub path        { __PACKAGE__->new(file => Mojo::File->new(@_)) }
sub child       { __PACKAGE__->new(file => shift->file->child(@_)) }
sub slurp       { shift()->file()->slurp() }
sub _chunk_size { int($_[0] / $_[1]) + (($_[0] % $_[1]) ? 1 : 0) }

sub split {
    my ($self, $chunk_size) = @_;
    return OpenQA::Files->new($self) unless $chunk_size < $self->size;
    my $residual = $self->size() % $chunk_size;
    my $n_chunks = _chunk_size($self->size(), $chunk_size);
    my $files    = OpenQA::Files->new();

    $n_chunks-- if $residual;

    for (my $i = 1; $i <= $n_chunks; $i++) {
        my $seek_start = ($i - 1) * $chunk_size;
        my $end        = $seek_start + $chunk_size;
        $files->add(
            $self->new(
                total => $n_chunks + 1,
                end   => $end,
                start => $seek_start,
                index => $i,
                file  => $self->file
            ));
    }

    $files->add(
        $self->new(
            total => $n_chunks + 1,
            end   => $files->last->end + $residual,
            start => $files->last->end,
            index => $n_chunks + 1,
            file  => $self->file
        )) if $residual;

    return $files;
}

sub read {
    my $self      = shift;
    my $file_name = ${$self->file};
    CORE::open my $file, '<', $file_name or croak "Can't open file $file_name: $!";
    my $ret = my $content = '';
    seek($file, $self->start(), 1);
    $ret = $file->sysread($content, ($self->end() - $self->start()));
    croak "Can't read from file $file_name : $!" unless defined $ret;
    return $content;
}

package OpenQA::Files {
    use Mojo::Base 'OpenQA::Parser::Results';

    sub compose {
        my $content;
        shift()->each(
            sub {
                $content .= $_->read();
            });
        $content;
    }
}

1;
