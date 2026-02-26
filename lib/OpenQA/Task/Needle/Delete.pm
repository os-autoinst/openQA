# Copyright 2019 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Task::Needle::Delete;
use Mojo::Base 'Mojolicious::Plugin', -signatures;

use OpenQA::Utils;
use Scalar::Util 'looks_like_number';
use Time::Seconds qw(ONE_HOUR ONE_DAY);
use OpenQA::Task::SignalGuard;
use Feature::Compat::Try;
use Carp qw(croak);

sub register {
    my ($self, $app) = @_;
    $app->minion->add_task(delete_needles => sub { _task_delete_needles($app, @_) });
}

sub restart_delay { $ENV{OPENQA_GRU_SERVER_RESTART_DELAY} // 5 }

sub _task_delete_needles ($app, $minion_job, $args) {
    # SignalGuard will prevent the delete task to interrupt with no recovery,
    # instead will retry once the gru server returned up and running. The popup
    # on the frontend will wait until the retried job finished.
    my $signal_guard = OpenQA::Task::SignalGuard->new($minion_job);
    my $schema = $app->schema;
    my $needles = $schema->resultset('Needles');
    my $user = $schema->resultset('Users')->find($args->{user_id});
    my $needle_ids = $args->{needle_ids};

    my (@errors, %to_remove);
    my @removed_ids = @{$minion_job->info->{notes}->{removed_ids} || []};
    my %removed = map { $_ => 1 } @removed_ids;
    for my $needle_id (@$needle_ids) {
        next if $removed{$needle_id};
        my $needle = looks_like_number($needle_id) ? $needles->find($needle_id) : undef;
        if (!$needle) {
            push @errors,
              {
                id => $needle_id,
                message => "Unable to find needle with ID \"$needle_id\"",
              };
            next;
        }
        push @{$to_remove{$needle->directory->path}}, $needle;
    }

    $signal_guard->retry(0);
    try {
        _delete_needles($app, $user, \%to_remove, \@removed_ids, \@errors);
    }
    catch ($e) {
        if (ref $e && $e->shutting_down) {
            $minion_job->note(removed_ids => \@removed_ids);
            # Explicitly set high value for expire, otherwise it would be only 60s
            return $minion_job->retry({delay => restart_delay, expire => ONE_DAY});
        }
        croak $e;
    }

    return $minion_job->finish(
        {
            removed_ids => \@removed_ids,
            errors => \@errors
        });
}

sub _delete_needles ($app, $user, $to_remove, $removed_ids, $errors) {
  DIR: for my $dir (sort keys %$to_remove) {
        my $needles = $to_remove->{$dir};
        # prevent multiple git tasks to run in parallel
        # note: The unless-block is covered by subtest 'minion guard' in t/14-grutasks-git.t which would fail when
        #       placing a "die" there. The coverage tracking does not seem to work for this block, though.
        my $guard;
        unless ($guard = $app->minion->guard("git_clone_${dir}_task", 2 * ONE_HOUR)) {
            my $msg = "Another git task for $dir is ongoing. Try again later.";    # uncoverable statement
            push @$errors, {id => $_->id, message => $msg} for @$needles;    # uncoverable statement
            next;    # uncoverable statement
        }
        for my $needle (@$needles) {
            my $needle_id = $needle->id;
            try {
                $needle->remove($user);
            }
            catch ($e) {
                croak $e if ref $e && $e->shutting_down;
                push @$errors,
                  {
                    id => $needle_id,
                    display_name => $needle->filename,
                    message => "$e",
                  };
                next;
            }
            push @$removed_ids, $needle_id;
        }
    }
}

1;
