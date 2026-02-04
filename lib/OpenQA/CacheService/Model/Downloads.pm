# Copyright 2019-2020 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::CacheService::Model::Downloads;
use Mojo::Base -base, -signatures;
use Feature::Compat::Try;
use Carp 'croak';

# Two days
use constant CLEANUP_AFTER => 172800;

has 'cache';

sub add ($self, $lock, $job_id) {
    try {
        my $db = $self->cache->sqlite->db;
        my $tx = $db->begin('exclusive');

        # Clean up entries that are older than 2 days
        $db->query(q{delete from downloads where created < datetime('now', '-' || ? || ' seconds')}, CLEANUP_AFTER);
        $db->insert('downloads', {lock => $lock, job_id => $job_id});

        $tx->commit;
    }
    catch ($e) { croak "Couldn't add download: $e" }    # uncoverable statement
}

sub find ($self, $lock) {
    my $db = $self->cache->sqlite->db;
    return undef unless my $hash = $db->select('downloads', ['job_id'], {lock => $lock}, {-desc => 'id'})->hash;
    return $hash->{job_id};
}

1;
