# Copyright 2014-2019 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Schema::Result::JobTemplates;

use strict;
use warnings;

use base 'DBIx::Class::Core';

__PACKAGE__->table('job_templates');
__PACKAGE__->load_components(qw(Timestamps));
__PACKAGE__->add_columns(
    id => {
        data_type => 'integer',
        is_auto_increment => 1,
    },
    product_id => {
        data_type => 'integer',
    },
    machine_id => {
        data_type => 'integer',
    },
    test_suite_id => {
        data_type => 'integer',
    },
    name => {
        data_type => 'text',
        default_value => '',
    },
    description => {
        data_type => 'text',
        default_value => '',
    },
    prio => {
        data_type => 'integer',
        is_nullable => 1,
    },
    group_id => {
        data_type => 'integer',
        is_foreign_key => 1,
    },
);
__PACKAGE__->add_timestamps;
__PACKAGE__->set_primary_key('id');
__PACKAGE__->belongs_to(product => 'OpenQA::Schema::Result::Products', 'product_id');
__PACKAGE__->belongs_to(machine => 'OpenQA::Schema::Result::Machines', 'machine_id');
__PACKAGE__->belongs_to(test_suite => 'OpenQA::Schema::Result::TestSuites', 'test_suite_id');
__PACKAGE__->belongs_to(group => 'OpenQA::Schema::Result::JobGroups', 'group_id');
__PACKAGE__->add_unique_constraint(scenario => [qw(product_id machine_id name test_suite_id)]);
__PACKAGE__->has_many(
    settings => 'OpenQA::Schema::Result::JobTemplateSettings',
    job_template_id => {order_by => {-asc => 'key'}});

=over 4

=item settings_hash()

Returns a hash with the assigned settings.

=back

=cut

sub settings_hash {
    my ($self) = @_;

    my $settings = $self->settings;
    my %settings_hash;
    while (my $setting = $settings->next) {
        $settings_hash{$setting->key} = $setting->value;
    }
    return \%settings_hash;
}

=over 4

=item to_hash()

Creates a hash for the job template including testsuite, machine and product details

This is used by the REST API so this function should stay compatible.

=back

=cut

sub to_hash {
    my ($self) = @_;

    my $product = $self->product;
    my $machine = $self->machine;
    my $test_suite = $self->test_suite;
    my $group = $self->group;
    my $settings = $self->settings_hash;

    my %result = (
        id => $self->id,
        prio => $self->prio,
        group_name => $group ? $group->name : '',
        product => {
            id => $product->id,
            arch => $product->arch,
            distri => $product->distri,
            flavor => $product->flavor,
            group => $product->mediagroup,
            version => $product->version,
        },
        machine => {
            id => $machine->id,
            name => $machine ? $machine->name : '',
        },
        test_suite => {
            id => $test_suite->id,
            name => $test_suite->name,
        },
    );
    if ($settings) {
        my @settings = sort { $a->key cmp $b->key } $self->settings;
        $result{settings} = [map { {key => $_->key, value => $_->value} } @settings] if @settings;
    }

    return \%result;
}

1;
