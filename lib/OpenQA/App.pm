# Copyright 2020 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::App;
use Mojo::Base -strict, -signatures;

my $SINGLETON;

sub set_singleton ($class, $app) { $SINGLETON = $app; }

sub singleton { $SINGLETON }

1;
