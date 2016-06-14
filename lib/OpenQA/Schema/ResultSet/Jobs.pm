# Copyright (C) 2014-2016 SUSE LLC
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
use base qw/DBIx::Class::ResultSet/;
use DBIx::Class::Timestamps qw/now/;
use OpenQA::Schema::Result::JobDependencies;

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
    my $self = shift;
    my %args = @_;
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
    $attrs{order_by} = {-desc => 'me.id'};              # More reliable for tests than t_created
    $attrs{columns}  = [{value => 'settings.value'}];
    push(@conds, {'settings.key' => {'=' => 'BUILD'}});

    while (my ($k, $v) = each %args) {
        my $subquery = $schema->resultset("JobSettings")->search(
            {
                key   => uc($k),
                value => $v
            });
        push(@conds, {'me.id' => {-in => $subquery->get_column('job_id')->as_query}});
    }

    my $rs = $self->search({-and => \@conds}, \%attrs);
    return $rs->get_column('value')->first;
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
        my $settings = $job->settings_hash;
        my $distri   = $settings->{DISTRI};
        my $version  = $settings->{VERSION};
        my $build    = $settings->{BUILD};
        my $test     = $settings->{TEST};
        my $flavor   = $settings->{FLAVOR} || 'sweet';
        my $arch     = $settings->{ARCH} || 'noarch';
        my $machine  = $settings->{MACHINE} || 'nomachine';
        my $key      = "$distri-$version-$build-$test-$flavor-$arch-$machine";
        next if $seen{$key}++;
        push(@latest, $job);
    }
    return @latest;
}

sub create_from_settings {
    my ($self, $settings) = @_;
    my %settings = %$settings;

    my %new_job_args = (test => $settings{TEST});

    if ($settings{NAME}) {
        my $njobs = $self->search({slug => $settings{NAME}})->count;
        return 0 if $njobs;

        $new_job_args{slug} = $settings{NAME};
        delete $settings{NAME};
    }

    if ($settings{_GROUP}) {
        $new_job_args{group} = {name => delete $settings{_GROUP}};
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

    return $job;
}

sub complex_query {
    my ($self, %args) = @_;
    # For args where we accept a list of values, allow passing either an
    # array ref or a comma-separated list
    for my $arg (qw/state ids result/) {
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
        push(@conds, {'me.result' => {-not_in => [OpenQA::Schema::Result::Jobs::INCOMPLETE_RESULTS]}});
    }
    my $scope = $args{scope} || '';
    if ($scope eq 'relevant') {
        push(@joins, 'clone');
        push(
            @conds,
            {
                -or => [
                    'me.clone_id' => undef,
                    'clone.state' => [OpenQA::Schema::Result::Jobs::PENDING_STATES],
                ],
                'me.result' => {    # these results should be hidden by default
                    -not_in => [
                        OpenQA::Schema::Result::Jobs::OBSOLETED,
                        # OpenQA::Schema::Result::Jobs::USER_CANCELLED  I think USER_CANCELLED jobs should be available for restart
                    ]}});
    }
    if ($scope eq 'current') {
        push(@conds, {'me.clone_id' => undef});
    }
    if ($args{limit}) {
        $attrs{rows} = $args{limit};
    }
    $attrs{page} = $args{page} || 0;
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
        # Text search across some settings
        my $subquery = $schema->resultset("JobSettings")->search(
            {
                key => ['DISTRI', 'FLAVOR', 'BUILD', 'TEST', 'VERSION'],
                value => {'-like' => "%$args{match}%"},
            });
        push(@conds, {'me.id' => {-in => $subquery->get_column('job_id')->as_query}});
    }
    else {
        my %js_settings = map { uc($_) => $args{$_} } qw(build iso distri version flavor arch hdd_1);
        my $subquery = $schema->resultset("JobSettings")->query_for_settings(\%js_settings);
        push(@conds, {'me.id' => {-in => $subquery->get_column('job_id')->as_query}});
    }

    $attrs{order_by} = ['me.id DESC'];

    $attrs{join} = \@joins if @joins;
    my $jobs = $self->search({-and => \@conds}, \%attrs);
    return $jobs;
}

1;
# vim: set sw=4 et:
