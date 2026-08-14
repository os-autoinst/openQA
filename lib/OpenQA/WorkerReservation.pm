# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::WorkerReservation;
use Mojo::Base -strict, -signatures;

use Exporter 'import';
use Scalar::Util 'blessed';
use OpenQA::WorkerReservation::Error;

our @EXPORT_OK = qw(RESERVATION_PROPERTIES RESERVATION_TIMESTAMP_FORMAT
  reservation_active reservation_error reservation_error_status);

# worker properties holding the reservation, reused to avoid a dedicated table and migration
use constant RESERVATION_PROPERTIES => qw(RESERVED_BY_ID RESERVED_COMMENT RESERVED_T_CREATED RESERVED_T_EXPIRES);
use constant RESERVATION_TIMESTAMP_FORMAT => '%Y-%m-%dT%H:%M:%SZ';

my %ERROR_STATUS = (invalid => 400, forbidden => 403, conflict => 409);

# a reservation is active while an owner is assigned and the optional expiry has not passed yet
sub reservation_active ($owner_id, $expires_epoch) { !!($owner_id && (!$expires_epoch || $expires_epoch > time)) }

sub reservation_error ($kind, $message) { OpenQA::WorkerReservation::Error->new($message)->kind($kind) }

sub reservation_error_status ($error) {
    my $kind = blessed $error && $error->isa('OpenQA::WorkerReservation::Error') ? $error->kind : undef;
    return $ERROR_STATUS{$kind // 'invalid'} // $ERROR_STATUS{invalid};
}

1;
