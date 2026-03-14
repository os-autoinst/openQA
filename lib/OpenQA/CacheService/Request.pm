# Copyright 2018-2019 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::CacheService::Request;
use Mojo::Base -base, -signatures;

use Carp 'croak';

has [qw(task minion_id)];

sub lock ($self) { croak 'lock() not implemented in ' . __PACKAGE__ }
sub to_array ($self) { croak 'to_array() not implemented in ' . __PACKAGE__ }

1;
