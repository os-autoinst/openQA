# Copyright (C) 2014-2017 SUSE LLC
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along
# with this program; if not, write to the Free Software Foundation, Inc.,
# 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.

package OpenQA::Schema::ResultSet::Jobs;
use strict;
use base 'DBIx::Class::ResultSet';
use DBIx::Class::Timestamps 'now';
use Date::Format 'time2str';
use OpenQA::Schema::Result::JobDependencies;
use OpenQA::Utils 'wakeup_scheduler';
use Cpanel::JSON::XS;

=head2 latest_build

=over

=item Arguments: hash with settings values to filter by

=item Return value: value of BUILD for the latests job matching the arguments

=back

Returns the value of the BUILD setting of the latest (most recently created)
job that matchs the settings provided as argument. Useful to find the
latest build for a given pair of distri and version.

=cut
sub latest_build {
    my ($self, %args) = @_;
    my @conds;
    my %attrs;
    my $rsource = $self->result_source;
    my $schema  = $rsource->schema;

    my $groupid = delete $args{groupid};
    if (defined $groupid) {
        push(@conds, {'me.group_id' => $groupid});
    }

    $attrs{join}     = 'settings';
    $attrs{rows}     = 1;
    $attrs{order_by} = {-desc => 'me.id'};    # More reliable for tests than t_created
    $attrs{columns}  = qw(BUILD);

    while (my ($k, $v) = each %args) {

        if (grep { $k eq $_ } qw(distri version flavor machine arch build test)) {
            push(@conds, {"me." . uc($k) => $v});
        }
        else {

            my $subquery = $schema->resultset("JobSettings")->search(
                {
                    key   => uc($k),
                    value => $v
                });
            push(@conds, {'me.id' => {-in => $subquery->get_column('job_id')->as_query}});
        }
    }

    my $rs = $self->search({-and => \@conds}, \%attrs);
    return $rs->get_column('BUILD')->first;
}

=head2 latest_jobs

=over

=item Return value: array of only the most recent jobs in the resultset

=back

De-duplicates the jobs in the result set. Jobs are considered 'duplicates'
if they are for the same DISTRI, VERSION, BUILD, TEST, FLAVOR, ARCH and
MACHINE. For each set of dupes, only the latest job found is included in
the return array.

=cut
sub latest_jobs {
    my ($self) = @_;

    my @jobs = $self->search(undef, {order_by => ['me.id DESC']});
    my @latest;
    my %seen;
    foreach my $job (@jobs) {
        my $test    = $job->TEST;
        my $distri  = $job->DISTRI;
        my $version = $job->VERSION;
        my $build   = $job->BUILD;
        my $flavor  = $job->FLAVOR;
        my $arch    = $job->ARCH;
        my $machine = $job->MACHINE // '';
        my $key     = "$distri-$version-$build-$test-$flavor-$arch-$machine";
        next if $seen{$key}++;
        push(@latest, $job);
    }
    return @latest;
}

sub create_from_settings {
    my ($self, $settings) = @_;
    my %settings = %$settings;

    my %new_job_args = (TEST => $settings{TEST});
    my $group;
    my %group_args;
    my $txn_guard = $self->result_source->storage->txn_scope_guard;

    if ($settings{_GROUP_ID}) {
        $group_args{id} = delete $settings{_GROUP_ID};
    }
    if ($settings{_GROUP}) {
        my $group_name = delete $settings{_GROUP};
        $group_args{name} = $group_name unless $group_args{id};
    }
    if (%group_args) {
        $group = $self->result_source->schema->resultset('JobGroups')->find(\%group_args);
        if ($group) {
            $new_job_args{group_id} = $group->id;
            $new_job_args{priority} = $group->default_priority;
        }
    }

    if ($settings{_START_AFTER_JOBS}) {
        my $ids = $settings{_START_AFTER_JOBS};    # support array ref or comma separated values
        $ids = [split(/\s*,\s*/, $ids)] if (ref($ids) ne 'ARRAY');
        for my $id (@$ids) {
            push @{$new_job_args{parents}},
              {
                parent_job_id => $id,
                dependency    => OpenQA::Schema::Result::JobDependencies::CHAINED,
              };
        }
        delete $settings{_START_AFTER_JOBS};
    }

    if ($settings{_PARALLEL_JOBS}) {
        my $ids = $settings{_PARALLEL_JOBS};    # support array ref or comma separated values
        $ids = [split(/\s*,\s*/, $ids)] if (ref($ids) ne 'ARRAY');
        for my $id (@$ids) {
            push @{$new_job_args{parents}},
              {
                parent_job_id => $id,
                dependency    => OpenQA::Schema::Result::JobDependencies::PARALLEL,
              };
        }
        delete $settings{_PARALLEL_JOBS};
    }
    # migrate the important keys
    for my $key (qw(DISTRI VERSION FLAVOR ARCH TEST MACHINE BUILD)) {
        my $value = delete $settings{$key};
        next unless $value;
        $new_job_args{$key} = $value;
    }

    my $job = $self->create(\%new_job_args);
    my @job_settings;

    # prepare the settings for bulk insert
    while (my ($k, $v) = each %settings) {
        my @values = ($v);
        if ($k eq 'WORKER_CLASS') {    # special case
            @values = split(m/,/, $v);
        }
        my $now = now;
        for my $l (@values) {
            push @job_settings, {job_id => $job->id, t_created => $now, t_updated => $now, key => $k, value => $l};
        }
    }

    $self->result_source->schema->resultset("JobSettings")->populate(\@job_settings);
    # this will associate currently available assets with job
    $job->register_assets_from_settings;

    if (%group_args && !$group) {
        OpenQA::Utils::log_warning(
            'Ignoring invalid group ' . encode_json(\%group_args) . ' when creating new job ' . $job->id);
    }
    $txn_guard->commit;
    wakeup_scheduler;
    return $job;
}

sub complex_query {
    my ($self, %args) = @_;

    # For args where we accept a list of values, allow passing either an
    # array ref or a comma-separated list
    for my $arg (qw(state ids result failed_modules)) {
        next unless $args{$arg};
        $args{$arg} = [split(',', $args{$arg})] unless (ref($args{$arg}) eq 'ARRAY');
    }

    my @conds;
    my %attrs;
    my @joins;

    unless ($args{idsonly}) {
        push @{$attrs{prefetch}}, 'settings';
        push @{$attrs{prefetch}}, 'parents';
        push @{$attrs{prefetch}}, 'children';
    }

    if ($args{failed_modules}) {
        push @joins, "modules";
        push(
            @conds,
            {
                'modules.name'   => {-in => $args{failed_modules}},
                'modules.result' => OpenQA::Jobs::Constants::FAILED,
            });
    }

    if ($args{state}) {
        push(@conds, {'me.state' => $args{state}});
    }
    if ($args{maxage}) {
        my $agecond = {'>' => time2str('%Y-%m-%d %H:%M:%S', time - $args{maxage}, 'UTC')};
        push(
            @conds,
            {
                -or => [
                    'me.t_created'  => $agecond,
                    'me.t_started'  => $agecond,
                    'me.t_finished' => $agecond
                ]});
    }
    # allows explicit filtering, e.g. in query url "...&result=failed&result=incomplete"
    if ($args{result}) {
        push(@conds, {'me.result' => {-in => $args{result}}});
    }
    if ($args{ignore_incomplete}) {
        push(@conds, {'me.result' => {-not_in => [OpenQA::Jobs::Constants::INCOMPLETE_RESULTS]}});
    }
    my $scope = $args{scope} || '';
    if ($scope eq 'relevant') {
        push(@joins, 'clone');
        push(
            @conds,
            {
                -or => [
                    'me.clone_id' => undef,
                    'clone.state' => [OpenQA::Jobs::Constants::PENDING_STATES],
                ],
                'me.result' => {    # these results should be hidden by default
                    -not_in => [
                        OpenQA::Jobs::Constants::OBSOLETED,
                        # OpenQA::Jobs::Constants::USER_CANCELLED
                        # I think USER_CANCELLED jobs should be available for restart
                    ]}});
    }
    if ($scope eq 'current') {
        push(@conds, {'me.clone_id' => undef});
    }
    if ($args{limit}) {
        $attrs{rows} = $args{limit};
    }
    $attrs{page} = $args{page} || 0;
    if ($args{before}) {
        push(@conds, {'me.id' => {'<', $args{before}}});
    }
    if ($args{after}) {
        push(@conds, {'me.id' => {'>', $args{after}}});
    }
    if ($args{assetid}) {
        push(@joins, 'jobs_assets');
        push(
            @conds,
            {
                'jobs_assets.asset_id' => $args{assetid},
            });
    }
    my $rsource = $self->result_source;
    my $schema  = $rsource->schema;

    if (defined $args{groupid}) {
        push(
            @conds,
            {
                'me.group_id' => $args{groupid} || undef,
            });
    }
    elsif ($args{group}) {
        my $subquery = $schema->resultset("JobGroups")->search({name => $args{group}})->get_column('id')->as_query;
        push(
            @conds,
            {
                'me.group_id' => {-in => $subquery},
            });
    }

    if ($args{ids}) {
        push(@conds, {'me.id' => {-in => $args{ids}}});
    }
    elsif ($args{match}) {
        my @likes;
        # Text search across some settings
        for my $key (qw(DISTRI FLAVOR BUILD TEST VERSION)) {
            push(@likes, {"me.$key" => {'-like' => "%$args{match}%"}});
        }
        push(@conds, -or => \@likes);
    }
    else {
        my %js_settings;
        # Check if the settings are between the arguments passed via query url
        # they come in lowercase, so mace sure $key is lc'ed
        for my $key (qw(ISO HDD_1 WORKER_CLASS)) {
            $js_settings{$key} = $args{lc $key} if defined $args{lc $key};
        }
        if (%js_settings) {
            my $subquery = $schema->resultset("JobSettings")->query_for_settings(\%js_settings);
            push(@conds, {'me.id' => {-in => $subquery->get_column('job_id')->as_query}});
        }

        for my $key (qw(build distri version flavor arch test machine)) {
            if ($args{$key}) {
                push(@conds, {"me." . uc($key) => $args{$key}});
            }
        }
    }

    $attrs{order_by} = ['me.id DESC'];

    $attrs{join} = \@joins if @joins;
    my $jobs = $self->search({-and => \@conds}, \%attrs);
    return $jobs;
}

sub cancel_by_settings {
    my ($self, $settings, $newbuild, $deprioritize, $deprio_limit) = @_;
    $newbuild     //= 0;
    $deprioritize //= 0;
    $deprio_limit //= 100;
    my $rsource = $self->result_source;
    my $schema  = $rsource->schema;
    # preserve original settings by deep copy
    my %precond = %{$settings};
    my %cond;

    for my $key (qw(DISTRI VERSION FLAVOR MACHINE ARCH BUILD TEST)) {
        if (defined $precond{$key}) {
            $cond{$key} = delete $precond{$key};
        }
    }
    if (%precond) {
        my $subquery = $schema->resultset('JobSettings')->query_for_settings(\%precond);
        $cond{id} = {-in => $subquery->get_column('job_id')->as_query};
    }
    $cond{state} = [OpenQA::Jobs::Constants::PENDING_STATES];
    my $jobs = $schema->resultset('Jobs')->search(\%cond);
    my $jobs_to_cancel;
    if ($newbuild) {
        # 'monkey patch' cond to be useable in chained search
        $cond{'me.id'} = delete $cond{id} if $cond{id};
        # filter out all jobs that have any comment (they are considered 'important') ...
        $jobs_to_cancel = $jobs->search({'comments.job_id' => undef}, {join => 'comments'});
        # ... or belong to a tagged build, i.e. is considered important
        # this might be even the tag 'not important' but not much is lost if
        # we still not cancel these builds
        my $groups_query     = $jobs->get_column('group_id')->as_query;
        my @important_builds = grep defined,
          map { ($_->tag)[0] } $schema->resultset('Comments')->search({'me.group_id' => {-in => $groups_query}});
        my @unimportant_jobs;
        while (my $j = $jobs_to_cancel->next) {
            # the value we get from that @important_builds search above
            # could be just BUILD or VERSION-BUILD
            next if grep ($j->BUILD eq $_, @important_builds);
            next if grep (join('-', $j->VERSION, $j->BUILD) eq $_, @important_builds);
            push @unimportant_jobs, $j->id;
        }
        # if there are only important jobs there is nothing left for us to do
        return 0 unless @unimportant_jobs;
        $jobs_to_cancel = $jobs_to_cancel->search({'me.id' => {-in => \@unimportant_jobs}});
    }
    else {
        $jobs_to_cancel = $jobs;
    }
    my $cancelled_jobs = 0;
    # first scheduled to avoid worker grab
    $jobs = $jobs_to_cancel->search({state => OpenQA::Jobs::Constants::SCHEDULED});
    while (my $j = $jobs->next) {
        $cancelled_jobs += _cancel_or_deprioritize($j, $newbuild, $deprioritize, $deprio_limit);
    }
    # then the rest
    $jobs = $jobs_to_cancel->search({state => [OpenQA::Jobs::Constants::EXECUTION_STATES]});
    while (my $j = $jobs->next) {
        $cancelled_jobs += _cancel_or_deprioritize($j, $newbuild, $deprioritize, $deprio_limit);
    }
    return $cancelled_jobs;
}

sub _cancel_or_deprioritize {
    my ($job, $newbuild, $deprioritize, $limit, $step) = @_;
    $step //= 10;
    if ($deprioritize) {
        my $prio = $job->priority + $step;
        if ($prio < $limit) {
            $job->set_prio($prio);
            return 0;
        }
    }
    return $job->cancel($newbuild);
}

sub next_previous_jobs_query {
    my ($self, $job, $jobid, %args) = @_;
    my $p_limit     = $args{previous_limit};
    my $n_limit     = $args{next_limit};
    my @inc_results = OpenQA::Jobs::Constants::INCOMPLETE_RESULTS;
    $inc_results[0] = '';

    my @params;
    push @params, 'done';
    push @params, @inc_results;
    for (1 .. 2) {
        for my $key (OpenQA::Schema::Result::Jobs::SCENARIO_WITH_MACHINE_KEYS) {
            push @params, $job->get_column($key);
        }
    }
    push @params, $jobid, $n_limit, $jobid, $p_limit, $jobid;

    my $jobs_rs = $self->result_source->schema->resultset('JobNextPrevious')->search(
        {},
        {
            bind => \@params
        });
    return $jobs_rs;
}

1;
# vim: set sw=4 et:
