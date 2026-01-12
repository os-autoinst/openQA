# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Error::Cmd;

use Mojo::Base 'OpenQA::Error', -signatures;

has [qw(status return_code stdout stderr)];

1;
