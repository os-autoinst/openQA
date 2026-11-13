# Copyright 2019 LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Schema::ResultSet::Bugs;

use Mojo::Base 'DBIx::Class::ResultSet', -signatures;
use OpenQA::App;

# inserts the bug if it is new, returns the bug if it has been refreshed, undef otherwise
sub get_bug ($self, $bugid = undef) {
    return undef unless $bugid;
    my $bug = $self->find({bugid => $bugid}) // $self->_insert_implicit($bugid);
    return ($bug && $bug->refreshed && $bug->existing) ? $bug : undef;
}

sub _insert_implicit ($self, $bugid) {
    my $dbh = $self->result_source->schema->storage->dbh;
    my $sth = $dbh->prepare_cached(<<~'END_SQL');
        INSERT INTO bugs (bugid, t_created, t_updated)
                    VALUES (?, now(), now())
        ON CONFLICT (bugid) DO NOTHING RETURNING id
        END_SQL
    $sth->execute($bugid);
    my ($id) = $sth->fetchrow_array;
    $sth->finish;
    return $self->find({bugid => $bugid}) unless $id;
    OpenQA::App->singleton->emit_event(openqa_bug_create => {id => $id, bugid => $bugid, implicit => 1});
    return undef;
}

1;
