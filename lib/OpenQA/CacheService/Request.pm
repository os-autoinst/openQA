# Copyright 2018-2019 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::CacheService::Request;
use Mojo::Base -base;

use Carp 'croak';

has [qw(task minion_id)];

sub lock { croak 'lock() not implemented in ' . __PACKAGE__ }
sub to_array { croak 'to_array() not implemented in ' . __PACKAGE__ }

1;
