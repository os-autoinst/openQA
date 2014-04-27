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

use Carp ();

# https://progress.opensuse.org/issues/2214
has variables => sub {
    return {
        map  { $_ => 1 }
          qw/
          ARCH
          BTRFS
          BUILD
          DESKTOP
          DISTRI
          DOCRUN
          DUALBOOT
          DVD
          ENCRYPT
          FLAVOR
          GNOME
          HDDMODEL
          HDDSIZEGB
          HDDVERSION
          HDD_1
          HDD_2
          INSTALLONLY
          ISO
          ISO_MAXSIZE
          KVM
          LAPTOP
          LIVECD
          LIVETEST
          LVM
          MACHINE
          NAME
          NICEVIDEO
          NICMODEL
          NOAUTOLOGIN
          NUMDISKS
          PROMO
          QEMUCPU
          QEMUCPUS
          QEMUVGA
          RAIDLEVEL
          REBOOTAFTERINSTALL
          REPO_1
          REPO_2
          RESCUECD
          SCREENSHOTINTERVAL
          SMP
          SPLITUSR
          TEST
          TOGGLEHOME
          UEFI
          UPGRADE
          USBBOOT
          VERSION
          VIDEOMODE
          /
    };
};

sub check {
    my $self = shift;
    my %args = @_;

    for my $i (qw/NAME/) {
        next unless $args{$i};
        die "invalid character in $i\n" if $args{$i} =~ /\//; # TODO: use whitelist?
    }

    while (my ($k, $v) = each %args) {
        return "$k invalid" unless exists $self->variables->{$k};
    }
    return undef;
}

1;
