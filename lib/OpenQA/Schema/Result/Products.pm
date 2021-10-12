# Copyright 2014 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Schema::Result::Products;

use strict;
use warnings;

use base 'DBIx::Class::Core';

__PACKAGE__->table('products');
__PACKAGE__->load_components(qw(Timestamps));
__PACKAGE__->add_columns(
    id => {
        data_type => 'integer',
        is_auto_increment => 1,
    },
    name => {
        data_type => 'text',
        accessor => '_name',
    },
    distri => {
        data_type => 'text',
    },
    version => {
        data_type => 'text',
        default_value => '',
    },
    arch => {
        data_type => 'text',
    },
    flavor => {
        data_type => 'text',
    },
    description => {
        data_type => 'text',
        is_nullable => 1,
    },
);
__PACKAGE__->add_timestamps;
__PACKAGE__->set_primary_key('id');
__PACKAGE__->has_many(job_templates => 'OpenQA::Schema::Result::JobTemplates', 'product_id');
__PACKAGE__->add_unique_constraint([qw(distri version arch flavor)]);
__PACKAGE__->has_many(
    settings => 'OpenQA::Schema::Result::ProductSettings',
    'product_id', {order_by => {-asc => 'key'}});

sub name {
    my ($self) = @_;
    join('-', map { $self->$_ } qw(distri version flavor arch));
}

# give all flavors of a "product" a common name
# used in the job groups display
sub mediagroup {
    my ($self) = @_;
    my $mediagroup = $self->distri . "-";
    if ($self->version ne '*') {
        $mediagroup .= $self->version . "-";
    }
    $mediagroup . $self->flavor;
}

1;
