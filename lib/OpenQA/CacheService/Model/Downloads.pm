# Copyright (C) 2019-2020 SUSE LLC
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
# with this program; if not, see <http://www.gnu.org/licenses/>.

package OpenQA::CacheService::Model::Downloads;
use Mojo::Base -base;

use Carp 'croak';

# Two days
use constant CLEANUP_AFTER => 172800;

has 'cache';

sub add {
    my ($self, $lock, $job_id) = @_;

    eval {
        my $db = $self->cache->sqlite->db;
        my $tx = $db->begin('exclusive');

        # Clean up entries that are older than 2 days
        $db->query(q{delete from downloads where created < datetime('now', '-' || ? || ' seconds')}, CLEANUP_AFTER);
        $db->insert('downloads', {lock => $lock, job_id => $job_id});

        $tx->commit;
    };
    if (my $err = $@) { croak "Couldn't add download: $err" }
}

sub find {
    my ($self, $lock) = @_;
    my $db = $self->cache->sqlite->db;
    return undef unless my $hash = $db->select('downloads', ['job_id'], {lock => $lock}, {-desc => 'id'})->hash;
    return $hash->{job_id};
}

1;
