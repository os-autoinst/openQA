# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Scheduler::WorkerSlotPicker;
use Mojo::Base -base, -signatures;

use List::Util qw(any);

sub new ($class, $to_be_scheduled) { $class->SUPER::new->reset($to_be_scheduled) }

sub reset ($self, $to_be_scheduled) {
    $self->{_to_be_scheduled} = $to_be_scheduled;
    $self->{_matching_worker_slots_by_host} = {};
    $self->{_visited_worker_slots_by_id} = {};
    $self->{_picked_matching_worker_slots} = [];
    $self->{_one_host_only} = 0;
    return $self;
}

sub _pick_next_slot_for_host_and_job ($self, $matching_worker_slots_for_host, $matching_worker, $job) {
    push @$matching_worker_slots_for_host, $matching_worker;
    $self->{_visited_worker_slots_by_id}->{$matching_worker->id} = $job;
    $self->{_one_host_only} ||= $self->_is_one_host_only($matching_worker);
    return undef if @$matching_worker_slots_for_host < @{$self->{_to_be_scheduled}};
    $self->{_picked_matching_worker_slots} = $matching_worker_slots_for_host;
}

sub _matching_worker_slots_for_host ($self, $host) { $self->{_matching_worker_slots_by_host}->{$host} //= [] }

sub _worker_host ($self, $worker) { $self->{_any_host} // $worker->host }

sub _is_one_host_only ($self, $worker) {
    my $cache = $self->{_is_one_host_only} //= {};
    my $worker_id = $worker->id;
    $cache->{$worker_id} //= $worker->get_property('PARALLEL_ONE_HOST_ONLY');
}

sub _reduce_matching_workers ($self) {
    # reduce the matching workers of each job to a single slot on the picked worker host's slots
    # note: If no single host provides enough matching slots ($picked_matching_worker_slots is still an
    #       empty arrayref) we assign an empty arrayref here. Then _allocate_jobs will not allocate any
    #       of those jobs and prioritize the jobs as usual via _allocate_worker_with_priority.
    my $picked_matching_worker_slots = $self->{_picked_matching_worker_slots};
    my $to_be_scheduled = $self->{_to_be_scheduled};
    for (my $i = 0; $i != @$to_be_scheduled; ++$i) {
        $to_be_scheduled->[$i]->{matching_workers} = [$picked_matching_worker_slots->[$i] // ()];
    }
    return $picked_matching_worker_slots;
}

sub _id_or_skip ($self, $worker, $visited_worker_slots_by_id) {
    my $id = $worker->id;
    # skip slots that have already been picked
    return undef if exists $visited_worker_slots_by_id->{$id};
    # skip slots with "PARALLEL_ONE_HOST_ONLY" to try picking on any other hosts instead
    return undef if $self->{_any_host} && $self->_is_one_host_only($worker);
    return $id;
}

sub _pick_one_matching_slot_per_host ($self, $job) {
    my $visited_worker_slots_by_id = $self->{_visited_worker_slots_by_id};
    my %visited_worker_slots_by_host;
    for my $matching_worker (@{$job->{matching_workers}}) {
        next unless my $id = $self->_id_or_skip($matching_worker, $visited_worker_slots_by_id);
        my $host = $self->_worker_host($matching_worker);
        next if $visited_worker_slots_by_host{$host}++;    # skip to pick only one slot per host
        last
          if $self->_pick_next_slot_for_host_and_job($self->_matching_worker_slots_for_host($host),
            $matching_worker, $job);
    }
    return \%visited_worker_slots_by_host;
}

sub _swap_slot_with_competitor_job ($self, $visited_worker_slots_by_host, $matching_worker) {
    # skip hosts we were able to pick a slot on
    my $host = $self->_worker_host($matching_worker);
    return 0 if $visited_worker_slots_by_host->{$host};

    # check the job we are competing with for this slot and see whether we might be able to swap picks by finding
    # the competing job an alternative slot
    my $id = $matching_worker->id;
    my $visited_worker_slots_by_id = $self->{_visited_worker_slots_by_id};
    return 0 unless my $competitor_job = $visited_worker_slots_by_id->{$id};
    my $matching_worker_slots = $self->_matching_worker_slots_for_host($host);
    for my $alternative_matching_worker (@{$competitor_job->{matching_workers}}) {
        # check whether the competitor can use this slot alternatively
        next unless my $alternative_id = $self->_id_or_skip($alternative_matching_worker, $visited_worker_slots_by_id);
        # skip the competitor's current slot for this host
        next if $id == $alternative_id;
        # skip slots that are not on the relevant host
        next if $self->{_one_host_only} && $self->_worker_host($alternative_matching_worker) ne $host;

        # make the competitor job use the alternative we have just found
        for (my $i = 0; $i != @$matching_worker_slots; ++$i) {
            next unless $matching_worker_slots->[$i]->id == $id;
            $matching_worker_slots->[$i] = $alternative_matching_worker;
            last;
        }
        $visited_worker_slots_by_id->{$alternative_id} = $competitor_job;
        $self->{_one_host_only} ||= $self->_is_one_host_only($alternative_matching_worker);
        return 1;
    }
    return 0;
}

sub _pick_one_slot_per_host_for_each_job ($self, $jobs) {
    for my $job (@$jobs) {
        # go through the list of matching worker slots and pick one slot per host
        my $visited_worker_slots_by_host = $self->_pick_one_matching_slot_per_host($job);

        # go tough the list of matching workers again to re-visit hosts we could not pick a slot on
        for my $matching_worker (@{$job->{matching_workers}}) {
            # use the slot from the competitor job if we found an alternative for the competitor job
            last
              if $self->_swap_slot_with_competitor_job($visited_worker_slots_by_host, $matching_worker)
              && $self->_pick_next_slot_for_host_and_job($self->_matching_worker_slots_for_host($matching_worker->host),
                $matching_worker, $job);
        }
    }
}

# reduces the matching workers of the jobs to be scheduled for pinning parallel jobs to single host
sub pick_slots_with_common_worker_host ($self) {
    # return early if we don't need to care about picking a common host for the given set of jobs
    my $to_be_scheduled = $self->{_to_be_scheduled};
    return undef if @$to_be_scheduled < 2;

    # determine whether only slots with a common worker host must be picked as per job settings
    my $one_host_only_per_job_settings = $self->{_one_host_only} = any { $_->{one_host_only} } @$to_be_scheduled;

    # let each job pick one slot per host
    $self->_pick_one_slot_per_host_for_each_job($to_be_scheduled);

    # do not reduce worker slots if there is no "PARALLEL_ONE_HOST_ONLY" job setting or worker property present
    return undef unless my $one_host_only = $self->{_one_host_only};

    # try assignment again without taking workers that have the "PARALLEL_ONE_HOST_ONLY" constraint into account
    # note: The algorithm so far took the first best worker slots it could find - including slots with the
    #       "PARALLEL_ONE_HOST_ONLY" constraint. Therefore the presence of a single matching worker slot with the
    #       "PARALLEL_ONE_HOST_ONLY" flag could easily prevent any matching jobs with parallel dependencies from
    #       being scheduled at all. To avoid this situation, let's re-run the algorithm without those worker slots.
    if (!@{$self->{_picked_matching_worker_slots}} && !$one_host_only_per_job_settings) {
        $self->reset($to_be_scheduled);
        $self->{_any_host} = 'any';
        $self->_pick_one_slot_per_host_for_each_job($to_be_scheduled);
    }

    return $self->_reduce_matching_workers;
}

1;
