# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Schema::Result::JobImpacts;

use Mojo::Base 'DBIx::Class::Core', -signatures;

use Mojo::JSON qw(decode_json encode_json);
use DateTime;

__PACKAGE__->table('job_impacts');
__PACKAGE__->load_components(qw(InflateColumn::DateTime DynamicDefault));
__PACKAGE__->add_columns(
    job_id => {
        data_type => 'integer',
        is_foreign_key => 1,
        is_nullable => 0,
    },
    seconds => {
        data_type => 'integer',
        is_nullable => 0,
    },
    vcpus => {
        data_type => 'real',
        is_nullable => 0,
    },
    ram_gb => {
        data_type => 'real',
        is_nullable => 0,
    },
    power_w => {
        data_type => 'real',
        is_nullable => 0,
    },
    energy_kwh => {
        data_type => 'double precision',
        is_nullable => 0,
    },
    carbon_g => {
        data_type => 'double precision',
        is_nullable => 0,
    },
    cost_energy => {
        data_type => 'double precision',
        is_nullable => 0,
    },
    cost_hardware => {
        data_type => 'double precision',
        is_nullable => 0,
    },
    cost_human => {
        data_type => 'double precision',
        is_nullable => 1,
    },
    cost_total => {
        data_type => 'double precision',
        is_nullable => 0,
    },
    currency => {
        data_type => 'text',
        is_nullable => 0,
    },
    model_version => {
        data_type => 'integer',
        is_nullable => 0,
    },
    factors => {
        data_type => 'jsonb',
        is_nullable => 0,
    },
    t_created => {
        data_type => 'timestamp with time zone',
        set_on_create => 1,
        dynamic_default_on_create => 'now',
        is_nullable => 0,
    },
);
__PACKAGE__->set_primary_key('job_id');
__PACKAGE__->resultset_class('OpenQA::Schema::ResultSet::JobImpacts');
__PACKAGE__->belongs_to(
    job => 'OpenQA::Schema::Result::Jobs',
    'job_id',
    {on_delete => 'CASCADE'},
);
__PACKAGE__->inflate_column(
    factors => {
        inflate => sub { decode_json(shift) },
        deflate => sub { encode_json(shift) },
    },
);

sub now ($self = undef) {
    DateTime->now(time_zone => 'UTC');
}

1;
