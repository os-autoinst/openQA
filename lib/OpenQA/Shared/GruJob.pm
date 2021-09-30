# Copyright 2018-2020 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Shared::GruJob;
use Mojo::Base 'Minion::Job';

use Data::Dumper 'Dumper';

sub execute {
    my $self = shift;

    my $gru_id = $self->info->{notes}{gru_id};
    my $err = $self->SUPER::execute;

    # Non-Gru tasks
    return $err unless $gru_id;

    my $info = $self->info;
    my $state = $info->{state};
    if ($state eq 'failed' || defined $err) {
        $err //= $info->{result};
        $err = Dumper($err) if ref $err;
        $self->app->log->error("Gru job error: $err");
        $self->fail($err);
        $self->_fail_gru($gru_id => $err);
    }

    # Avoid a possible race condition where the task retries the job and it gets
    # picked up by a new worker before we reach this line (by checking the
    # "finish" return value)
    elsif ($state eq 'active') { $self->_delete_gru($gru_id) if $self->finish('Job successfully executed') }

    elsif ($state eq 'finished') { $self->_delete_gru($gru_id) }

    return undef;
}

sub _delete_gru {
    my ($self, $id) = @_;
    my $gru = $self->minion->app->schema->resultset('GruTasks')->find($id);
    $gru->delete() if $gru;
}

sub _fail_gru {
    my ($self, $id, $reason) = @_;
    my $gru = $self->minion->app->schema->resultset('GruTasks')->find($id);
    $gru->fail($reason) if $gru;
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
