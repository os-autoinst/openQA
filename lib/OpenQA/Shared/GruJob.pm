# Copyright 2018-2020 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Shared::GruJob;
use Mojo::Base 'Minion::Job', -signatures;

use Mojo::Util qw(dumper);
use OpenQA::Log qw(log_debug);

sub _grutasks ($self) { $self->minion->app->schema->resultset('GruTasks'); }

sub execute ($self) {
    my $notes = $self->info->{notes};
    return $self->finish if $notes->{obsolete};
    my $gru_id = $notes->{gru_id};
    if ($gru_id and not $self->info->{finished}) {
        # We have a gru_id and this is the first run of the job
        my $gru = $self->_grutasks->find($gru_id);
        # GruTask might not yet have landed in database due to open transaction
        unless ($gru) {
            my $max_retries = $self->app->config->{misc_limits}->{wait_for_grutask_retries};
            my $retried = $self->info->{retries};
            my $delay = 2**(1 + $retried);
            my $msg = "Could not find GruTask '$gru_id' after $retried retries";
            if ($retried > $max_retries) {
                return $self->note(stop_reason => "$msg, giving up");
            }
            log_debug("$msg, delaying ${delay}s");
            return $self->retry({delay => $delay});
        }
    }
    my $err = $self->SUPER::execute;
    return $err unless $gru_id;    # Non-Gru tasks
    my $info = $self->info;
    my $state = $info->{state};
    my $user_error = $info->{notes}->{user_error};
    $err = $info->{result} if !$err && $state eq 'failed';
    $err = $user_error if !$err && $user_error;
    $err = dumper($err) if ref $err;
    if ($err) {
        unless ($user_error) {
            $self->app->log->error("Gru job error: $err");
            $self->fail($err);
        }
        $self->_fail_gru($gru_id, $err);
    }

    # Avoid a possible race condition where the task retries the job and it gets
    # picked up by a new worker before we reach this line (by checking the
    # "finish" return value)
    elsif ($state eq 'active') { $self->_delete_gru($gru_id) if $self->finish('Job successfully executed') }

    elsif ($state eq 'finished') { $self->_delete_gru($gru_id) }

    return undef;
}

sub _delete_gru ($self, $id) { $self->_grutasks->search({id => $id})->delete; }

sub _fail_gru ($self, $id, $reason) {
    if (my $gru = $self->_grutasks->find($id)) { $gru->fail($reason) }
}

sub user_fail ($self, $result) {
    $self->note(user_error => $result);
    $self->finish($result);
}

1;

=encoding utf8

=head1 NAME

OpenQA::Shared::GruJob - A Gru Job

=head1 SYNOPSIS

    use OpenQA::Shared::GruJob;

=head1 DESCRIPTION

L<OpenQA::Shared::GruJob> is a subclass of L<Minion::Job> used by
L<OpenQA::Shared::Plugin::Gru> that adds Gru metadata handling and TTL support.

=cut
