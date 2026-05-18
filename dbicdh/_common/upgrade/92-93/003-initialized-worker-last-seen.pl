#!/usr/bin/env perl

# Copyright 2020 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use strict;
use warnings;

sub {
    my ($schema) = @_;

    $_->update({t_seen => $_->t_updated}) for $schema->resultset('Workers')->all;
  }
