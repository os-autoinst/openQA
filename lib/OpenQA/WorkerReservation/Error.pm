# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::WorkerReservation::Error;
use Mojo::Base 'Mojo::Exception', -signatures;

# one of the kinds listed in OpenQA::WorkerReservation::ERROR_STATUS
has 'kind';

1;
