# Copyright 2019 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::WebAPI::Plugin::MIMETypes;
use Mojo::Base 'Mojolicious::Plugin';

sub register {
    my ($self, $app) = @_;

    my $types = $app->types;
    $types->type(yaml => 'text/yaml;charset=UTF-8');
    $types->type(bz2 => 'application/x-bzip2');
    $types->type(xz => 'application/x-xz');
}

1;
