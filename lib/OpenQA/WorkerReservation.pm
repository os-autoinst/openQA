# Copyright 2026 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::WorkerReservation;
use Mojo::Base -strict, -signatures;

use Exporter 'import';
use Scalar::Util 'blessed';
use OpenQA::WorkerReservation::Error;
use DateTime;

our @EXPORT_OK = qw(RESERVATION_PROPERTIES RESERVATION_TIMESTAMP_FORMAT
  reservation_active reservation_error reservation_error_status reservation_info reservation_class_valid);

# worker properties holding the reservation, reused to avoid a dedicated table and migration
use constant RESERVATION_PROPERTIES =>
  qw(RESERVED_BY_ID RESERVED_COMMENT RESERVED_T_CREATED RESERVED_T_EXPIRES RESERVED_WORKER_CLASS);
use constant RESERVATION_TIMESTAMP_FORMAT => '%Y-%m-%dT%H:%M:%SZ';

my %ERROR_STATUS = (invalid => 400, forbidden => 403, conflict => 409);

# a reservation is active while an owner is assigned and the optional expiry has not passed yet
sub reservation_active ($owner_id, $expires_epoch) { !!($owner_id && (!$expires_epoch || $expires_epoch > time)) }

sub reservation_class_valid ($tag) {
    return defined $tag && length $tag && $tag =~ /^[\w#.:-]+$/;
}

sub reservation_error ($kind, $message) { OpenQA::WorkerReservation::Error->new($message)->kind($kind) }

sub reservation_error_status ($error) {
    my $kind = blessed $error && $error->isa('OpenQA::WorkerReservation::Error') ? $error->kind : undef;
    return $ERROR_STATUS{$kind // 'invalid'} // $ERROR_STATUS{invalid};
}

sub _iso_timestamp ($epoch) {
    $epoch ? DateTime->from_epoch(epoch => $epoch, time_zone => 'UTC')->strftime(RESERVATION_TIMESTAMP_FORMAT) : undef;
}

sub reservation_info ($properties) {
    my $info = {
        user_id => $properties->{RESERVED_BY_ID},
        comment => $properties->{RESERVED_COMMENT},
        t_created => _iso_timestamp($properties->{RESERVED_T_CREATED}),
        t_expires => _iso_timestamp($properties->{RESERVED_T_EXPIRES}),
    };
    $info->{worker_class} = $properties->{RESERVED_WORKER_CLASS}
      if defined $properties->{RESERVED_WORKER_CLASS} && length $properties->{RESERVED_WORKER_CLASS};
    return $info;
}

1;
