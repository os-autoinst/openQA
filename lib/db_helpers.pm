# Copyright (C) 2014 SUSE Linux Products GmbH
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

package db_helpers;

use Mojo::Base 'Exporter';
our @EXPORT_OK = qw/create_auto_timestamps rndstr rndhex rndstrU rndhexU/;

use Carp;

sub rndstr{
    my $length = shift || 16;
    my $chars = shift || ['a'..'z', 'A'..'Z', '0'..'9', '_'];
    return join('', map { $chars->[rand @$chars] } 1 .. $length);
}

sub rndhex{
    rndstr(shift, ['A'..'F', '0'..'9']);
}

sub _rb{
    my ($fd, $max) = @_;
    my $b;
    read($fd, $b, 1) || croak "can't read random byte: $!";
    return int($max * ord($b)/256.0);
}

sub rndstrU{
    my $length = shift || 16;
    my $chars = shift || ['a'..'z', 'A'..'Z', '0'..'9', '_'];
    open(my $fd,  '<:raw:bytes', '/dev/urandom') || croak "can't open /dev/urandom: $!";
    my $str = join('', map { $chars->[_rb($fd, scalar @$chars)] } 1 .. $length);
    close $fd;
    return $str;
}

sub rndhexU{
    my $length = shift || 16;
    my $toread = $length/2+$length%2;
    open(my $fd,  '<:raw:bytes', '/dev/urandom') || croak "can't open /dev/urandom: $!";
    read($fd, my $bytes, $toread) || croak "can't read random byte: $!";
    close $fd;
    return uc substr(unpack('H*', $bytes), 0, $length);
}

1;
# vim: set sw=4 et:
