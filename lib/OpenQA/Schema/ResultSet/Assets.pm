# Copyright (C) 2014-2016 SUSE LLC
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

package OpenQA::Schema::ResultSet::Assets;
use strict;
use base qw/DBIx::Class::ResultSet/;
use OpenQA::Utils qw/log_warning/;

sub register {
    my ($self, $type, $name) = @_;

    our %types = map { $_ => 1 } qw/iso repo hdd other/;
    unless ($types{$type}) {
        log_warning "asset type '$type' invalid";
        return;
    }
    unless ($name && $name =~ /^[0-9A-Za-z+-._]+$/ && -e join('/', $OpenQA::Utils::assetdir, $type, $name)) {
        log_warning "asset name '$name' invalid or does not exist";
        return;
    }
    my $asset = $self->find_or_create(
        {
            type => $type,
            name => $name,
        },
        {
            key => 'assets_type_name',
        });
    return $asset;
}


1;
