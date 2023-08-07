# Copyright 2019 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::WebAPI::Controller::Admin::Influxdb;
use Mojo::Base 'Mojolicious::Controller', -signatures;
use DateTime;

use OpenQA::Jobs::Constants;

sub _queue_sub_stats ($query, $state, $result) {
    $result->{openqa_jobs}->{$state} = $query->count;
    my $counts = $query->search({},
        {select => ['group_id', {count => 'id'}], as => [qw(group_id count)], group_by => 'group_id'});
    while (my $c = $counts->next) {
        $result->{by_group}->{$c->get_column('group_id') // 0}->{$state} = $c->get_column('count');
    }
    my $archs = $query->search({}, {select => ['ARCH', {count => 'id'}], as => [qw(ARCH count)], group_by => 'ARCH'});
    while (my $c = $archs->next) {
        $result->{openqa_jobs_by_arch}->{"arch=" . $c->get_column('ARCH')}->{$state} = $c->get_column('count');
    }
}

sub _queue_output_measure ($url, $key, $tag, $states, $timestamp = undef) {
    my $line = "$key,url=$url";
    if ($tag) {
        $tag =~ s, ,\\ ,g;
        $line .= ",$tag";
    }
    $line .= " ";
    $line .= join(',', map { "$_=$states->{$_}i" } sort keys %$states);
    $line .= ' ' . $timestamp->epoch() * 1e9 if defined $timestamp;
    return $line . "\n";
}

# Renders a summary of jobs scheduled and running for monitoring
sub jobs ($self) {
    my $result = {};

    my $schema = $self->schema;
    my $jobs = $schema->resultset('Jobs');
    my $rs = $jobs->search({state => OpenQA::Jobs::Constants::SCHEDULED, blocked_by_id => undef});
    _queue_sub_stats($rs, 'scheduled', $result);
    $rs = $jobs->search({state => OpenQA::Jobs::Constants::SCHEDULED, -not => {blocked_by_id => undef}});
    _queue_sub_stats($rs, 'blocked', $result);
    $rs = $jobs->search({state => [OpenQA::Jobs::Constants::EXECUTION_STATES]});
    _queue_sub_stats($rs, 'running', $result);
    $rs = $jobs->search(
        {state => [OpenQA::Jobs::Constants::EXECUTION_STATES]},
        {
            join => [qw(assigned_worker)],
            select => ['assigned_worker.host', {count => 'job_id'}],
            as => [qw(host count)],
            group_by => 'assigned_worker.host'
        });

    while (my $c = $rs->next) {
        next unless $c->get_column('count');
        $result->{openqa_jobs_by_worker}->{"worker=" . $c->get_column('host')}->{running} = $c->get_column('count');
    }

    # map group ids to names (and group by parent)
    my $groups = $self->schema->resultset('JobGroups')->search({}, {prefetch => 'parent', select => [qw(id name)]});
    while (my $g = $groups->next) {
        my $name = $g->name;
        $name = $g->parent->name if $g->parent;
        my $states = $result->{by_group}->{$g->id};
        next unless $states;
        my $merged = $result->{openqa_jobs_by_group}->{"group=$name"} || {};
        for my $state (keys %$states) {
            $merged->{$state} = ($merged->{$state} // 0) + $states->{$state};
        }
        $result->{openqa_jobs_by_group}->{"group=$name"} = $merged;
    }
    if (my $group = $result->{by_group}->{0}) {
        $result->{openqa_jobs_by_group}->{"group=No Group"} = $group;
    }

    my $url = $self->app->config->{global}->{base_url} || $self->req->url->base->to_string;
    my $text = '';
    $text .= _queue_output_measure($url, 'openqa_jobs', undef, $result->{openqa_jobs});
    for my $key (qw(openqa_jobs_by_group openqa_jobs_by_worker openqa_jobs_by_arch)) {
        for my $tag (sort keys %{$result->{$key}}) {
            $text .= _queue_output_measure($url, $key, $tag, $result->{$key}->{$tag});
        }
    }

    $self->render(text => $text);
}

sub minion ($self) {
    my $stats = $self->app->minion->stats;
    my $block_list = $self->app->config->{influxdb}->{ignored_failed_minion_jobs} || [];
    my $filter_jobs_num = $self->app->minion->jobs({states => ['failed'], tasks => $block_list})->total;

    my $validation = $self->validation;
    $validation->optional('rc_fail_timespan_minutes')->num;
    return $self->reply->validation_error({format => 'json'}) if $validation->has_error;
    my $rc_fail_timespan_minutes = $validation->param('rc_fail_timespan_minutes') // 10;

    my $rc_fail_timespan_end = DateTime->now->truncate(to => 'minute');
    # go back to last full $rc_fail_timespan_minutes minutes mark (eg from 10:37 to 10:30)
    $rc_fail_timespan_end->subtract(minutes => ($rc_fail_timespan_end->minute() % $rc_fail_timespan_minutes));
    # make timespan $rc_fail_timespan_minutes minutes long (eg. range from 10:20 until 10:30)
    my $rc_fail_timespan_start = $rc_fail_timespan_end->clone()->subtract(minutes => $rc_fail_timespan_minutes);

    my $dbh = $self->schema->storage->dbh;
    # rc means hook script return code
    my $sth = $dbh->prepare(
        q{SELECT COUNT(*) AS rc_failed_count FROM minion_jobs
		  WHERE finished >= ? AND finished < ? AND task = 'hook_script' AND
		        state = 'finished' AND (notes->'hook_rc')::int != 0}
    );
    $sth->execute($rc_fail_timespan_start, "$rc_fail_timespan_end+0");

    my $result = $sth->fetchrow_arrayref;
    my $jobs_hook_rc_failed_count = $result->[0];

    my $jobs = {
        active => $stats->{active_jobs},
        delayed => $stats->{delayed_jobs},
        failed => $stats->{failed_jobs} - $filter_jobs_num,
        inactive => $stats->{inactive_jobs}};
    my $jobs_hook_rc_failed = {"rc_failed_per_${rc_fail_timespan_minutes}min" => $jobs_hook_rc_failed_count};
    my $workers = {
        registered => $stats->{workers},
        active => $stats->{active_workers},
        inactive => $stats->{inactive_workers}};

    my $url = $self->app->config->{global}->{base_url} || $self->req->url->base->to_string;
    my $text = '';
    $text .= _queue_output_measure($url, 'openqa_minion_jobs', undef, $jobs);
    $text .= _queue_output_measure($url, 'openqa_minion_jobs_hook_rc_failed',
        undef, $jobs_hook_rc_failed, $rc_fail_timespan_end);
    $text .= _queue_output_measure($url, 'openqa_minion_workers', undef, $workers);

    $self->render(text => $text, format => 'txt');
}

1;
