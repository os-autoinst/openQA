# Copyright 2019 LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Schema::ResultSet::Bugs;

use Mojo::Base 'DBIx::Class::ResultSet', -signatures;
use OpenQA::App;

# inserts the bug if it is new, returns the bug if it has been refreshed, undef otherwise
sub get_bug ($self, $bugid = undef, %attrs) {
    return unless $bugid;
    my $bug = $self->find_or_new({bugid => $bugid, %attrs});
    return ($bug->refreshed && $bug->existing) ? $bug : undef if $bug->in_storage;
    $bug->insert;
    OpenQA::App->singleton->emit_event(openqa_bug_create => {id => $bug->id, bugid => $bug->bugid, implicit => 1});
    return undef;
}

1;
