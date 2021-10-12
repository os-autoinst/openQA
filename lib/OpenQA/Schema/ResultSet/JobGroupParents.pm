# Copyright 2020 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Schema::ResultSet::JobGroupParents;

use strict;
use warnings;

use base 'DBIx::Class::ResultSet';

# query group parents and job groups and let the database sort it for us - and merge it afterwards
sub job_groups_and_parents {
    my $self = shift;

    my @parents = $self->search({}, {order_by => [{-asc => 'sort_order'}, {-asc => 'name'}]})->all;
    my $schema = $self->result_source->schema;
    my @groups_without_parent = $schema->resultset('JobGroups')
      ->search({parent_id => undef}, {order_by => [{-asc => 'sort_order'}, {-asc => 'name'}]})->all;
    my @res;
    my $first_parent = shift @parents;
    my $first_group = shift @groups_without_parent;
    while ($first_parent || $first_group) {
        my $pick_parent
          = $first_parent && (!$first_group || ($first_group->sort_order // 0) > ($first_parent->sort_order // 0));
        if ($pick_parent) {
            push(@res, $first_parent);
            $first_parent = shift @parents;
        }
        else {
            push(@res, $first_group);
            $first_group = shift @groups_without_parent;
        }
    }

    return \@res;
}

1;
