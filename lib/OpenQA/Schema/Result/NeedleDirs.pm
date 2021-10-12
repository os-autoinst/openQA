# Copyright 2015 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Schema::Result::NeedleDirs;

use strict;
use warnings;

use base 'DBIx::Class::Core';

__PACKAGE__->table('needle_dirs');
__PACKAGE__->add_columns(
    id => {
        data_type => 'integer',
        is_auto_increment => 1,
    },
    path => {
        data_type => 'text',
        is_nullable => 0
    },
    name => {
        data_type => 'text'
    },
);
__PACKAGE__->set_primary_key('id');
__PACKAGE__->add_unique_constraint([qw(path)]);

__PACKAGE__->has_many(needles => 'OpenQA::Schema::Result::Needles', 'dir_id');

sub set_name_from_job {
    my ($self, $job) = @_;

    $self->name(sprintf('%s-%s', $job->DISTRI, $job->VERSION));
}

1;
