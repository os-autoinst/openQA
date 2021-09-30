# Copyright 2015 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Schema::Result::JobLocks;

use strict;
use warnings;

use base 'DBIx::Class::Core';

__PACKAGE__->load_components(qw(OptimisticLocking Core));
__PACKAGE__->load_components(qw(Core));
__PACKAGE__->table('job_locks');
__PACKAGE__->add_columns(
    name => {
        data_type => 'text',
        is_nullable => 0,
    },
    owner => {
        data_type => 'integer',
        is_foreign_key => 1,
        is_nullable => 0,
    },
    locked_by => {
        data_type => 'text',
        is_nullable => 1,
        default_value => undef,
    },
    count => {
        data_type => 'integer',
        default_value => 1,
        is_nullable => 0
    });

__PACKAGE__->set_primary_key('name', 'owner');
__PACKAGE__->belongs_to(owner => 'OpenQA::Schema::Result::Jobs', 'owner');


# translate job ids stored in locked_by to jobs
sub locked_by_jobs {
    my ($self) = @_;
    my $rsource = $self->result_source;
    my $schema = $rsource->schema;

    return unless $self->locked_by;
    my @locked_ids = split(/,/, $self->locked_by);
    return $schema->resultset('Jobs')->search({id => {-in => \@locked_ids}})->all;
}

1;
