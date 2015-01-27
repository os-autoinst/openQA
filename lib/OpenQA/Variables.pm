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

package OpenQA::Variables;

use strict;
use warnings;

use Mojo::Base -base;

use OpenQA::Utils qw/testcasedir/;

use Carp ();
use Data::Dump;


# https://progress.opensuse.org/issues/2214
our $variables = {};

our %DEFAULT_VARIABLES = (
    NAME => {},
    DISTRI => {},
    VERSION => {},
    TEST => {},
);

sub get {
    my $self = shift;
    my $distri = shift;
    my $version = shift;
    my $variable = shift;
    my $h = $variables->{$distri}->{$version} || {};
    unless ($h) {
        $variables->{$distri}->{$version} = {%DEFAULT_VARIABLES};
    }
    my $file = testcasedir($distri, $version).'/variables';
    if (open(my $fd, '<', $file)) {
        my @s = stat($fd);
        if (($h->{'.mtime'}||-1) != $s[9]) {
            $h = {%DEFAULT_VARIABLES};
            $h->{'.mtime'} = $s[9];
            while (<$fd>) {
                chomp;
                # TODO: parste type information or make this even a real file format
                my ($name, $type) = split(/ +/, $_, 2);
                if ($h->{$name}) {
                    warn "$file: $name redefined\n";
                    next;
                }
                $h->{$name} = {};
            }
            close $fd;
            $variables->{$distri}->{$version} = $h;
        }
    }
    else {
        warn "$file: $!\n";
    }
    return $h->{$variable} if $variable;
    return $h;
}

sub new {
    my $self = shift->SUPER::new(@_);
    return $self;
}

sub check {
    my $self = shift;
    my %args = @_;

    for my $i (qw/DISTRI VERSION TEST/) {
        die "need one $i key\n" unless exists $args{$i};
    }

    for my $i (qw/NAME DISTRI VERSION/) {
        next unless $args{$i};
        die "invalid character in $i\n" if $args{$i} =~ /\// || $args{$i} =~ /\.\./; # TODO: use whitelist?
    }

    # don't do this for now, accept any and let os-autoinst handle the sanitizing
    #
    #    my @invalid;
    #    while (my ($k, $v) = each %args) {
    #        next if defined $self->get($args{DISTRI}, $args{VERSION}, $k);
    #        push @invalid, $k;
    #    }
    #    return 'invalid variables: '.join(' ', sort @invalid) if @invalid;
    #
    return undef;
}

1;
