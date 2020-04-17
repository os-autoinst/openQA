# Copyright (C) 2019-2020 SUSE LLC
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License

package OpenQA::JobSettings;

use strict;
use warnings;

# replace %NAME% with $settings{NAME}
sub expand_placeholders {
    my ($settings) = @_;

    for my $value (values %$settings) {
        next unless defined $value;

        my %visited_top_level_placeholders;

        eval { $value =~ s/%(\w+)%/_expand_placeholder($settings, $1, \%visited_top_level_placeholders)/eg; };
        if ($@) {
            return "Error: $@";
        }
    }
    return undef;
}

sub _expand_placeholder {
    my ($settings, $key, $visited_placeholders_in_parent_scope) = @_;

    return '' unless defined $settings->{$key};

    my %visited_placeholders = %$visited_placeholders_in_parent_scope;
    if ($visited_placeholders{$key}++) {
        die "The key $key contains a circular reference, its value is $settings->{$key}.\n";
    }

    my $value = $settings->{$key};
    $value =~ s/%(\w+)%/_expand_placeholder($settings, $1, \%visited_placeholders)/eg;

    return $value;
}

# allow some messing with the usual precedence order. If anything
# sets +VARIABLE, that setting will be used as VARIABLE regardless
# (so a product or template +VARIABLE beats a post'ed VARIABLE).
# if *multiple* things set +VARIABLE, whichever comes highest in
# the usual precedence order wins.
sub handle_plus_in_settings {
    my ($settings) = @_;
    for (keys %$settings) {
        if (substr($_, 0, 1) eq '+') {
            $settings->{substr($_, 1)} = delete $settings->{$_};
        }
    }
}

1;
