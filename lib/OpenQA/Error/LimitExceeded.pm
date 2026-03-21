# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Error::LimitExceeded;

use Mojo::Base 'OpenQA::Error', -signatures;

has [qw(build limit count)];

1;
