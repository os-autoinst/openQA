# Copyright 2014 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Schema::Result::ApiKeys;

use strict;
use warnings;

use base 'DBIx::Class::Core';

use OpenQA::Utils 'random_hex';

__PACKAGE__->table('api_keys');
__PACKAGE__->load_components(qw(InflateColumn::DateTime Timestamps));
__PACKAGE__->add_columns(
    id => {
        data_type => 'integer',
        is_auto_increment => 1,
    },
    key => {
        data_type => 'text',
    },
    secret => {
        data_type => 'text',
    },
    user_id => {
        data_type => 'integer',
        is_foreign_key => 1,
    },
    t_expiration => {
        data_type => 'timestamp',
        is_nullable => 1,
    },
);
__PACKAGE__->add_timestamps;
__PACKAGE__->set_primary_key('id');
__PACKAGE__->add_unique_constraint([qw(key)]);
__PACKAGE__->belongs_to(user => 'OpenQA::Schema::Result::Users', 'user_id');

sub new {
    my ($class, $attrs) = @_;

    $attrs->{key} = random_hex() unless $attrs->{key};
    $attrs->{secret} = random_hex() unless $attrs->{secret};

    my $new = $class->next::method($attrs);
    return $new;
}

1;
