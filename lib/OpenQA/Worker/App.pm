# Copyright 2020 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Worker::App;
use Mojo::Base 'Mojolicious';

has [qw(log_name level instance log_dir)];

# This is a mock application, so OpenQA::Setup can be reused to set up logging
# for the workers
sub startup {
    my $self = shift;
    $self->mode('production');
}

1;
