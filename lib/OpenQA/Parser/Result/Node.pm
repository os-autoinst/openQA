# Copyright 2017-2019 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Parser::Result::Node;
use Mojo::Base 'OpenQA::Parser::Result';

has 'val';

sub AUTOLOAD {
    our $AUTOLOAD;
    my $fn = $AUTOLOAD;
    $fn =~ s/.*:://;
    return shift->get($fn);
}

sub get {
    my ($self, $name) = @_;
    return $self->new(val => $self->val->{$name});
}

1;
