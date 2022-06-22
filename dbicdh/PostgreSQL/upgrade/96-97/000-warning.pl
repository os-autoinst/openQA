#!/usr/bin/env perl

# Copyright 2022 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use strict;
use OpenQA::Log qw(log_warning);

sub {
    log_warning 'Further database IDs will be converted to bigint. That may take multiple hours on big databases.'
              . ' It is safe to stop the service (and start from scratch on the next startup).';
}
