# Copyright 2017-2019 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Parser::Result::Node;
use Mojo::Base 'OpenQA::Parser::Result', -signatures;

has 'val';

sub AUTOLOAD ($self, @args) {
    our $AUTOLOAD;
    my $fn = $AUTOLOAD;
    $fn =~ s/.*:://;
    return $self->get($fn);
}

sub get ($self, $name) {
    return $self->new(val => $self->val->{$name});
}

1;
