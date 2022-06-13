# Copyright 2014 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Schema::Result::Secrets;


use Mojo::Base 'DBIx::Class::Core';

use OpenQA::Utils 'random_hex';

__PACKAGE__->table('secrets');
__PACKAGE__->load_components(qw(InflateColumn::DateTime Timestamps));
__PACKAGE__->add_columns(
    id => {
        data_type => 'bigint',
        is_auto_increment => 1,
    },
    secret => {
        data_type => 'text',
    },
);
__PACKAGE__->add_timestamps;
__PACKAGE__->set_primary_key('id');
__PACKAGE__->add_unique_constraint([qw(secret)]);

sub new {
    my ($class, $attrs) = @_;

    $attrs->{secret} = random_hex(32) unless $attrs->{secret};

    my $new = $class->next::method($attrs);
    return $new;
}

1;
