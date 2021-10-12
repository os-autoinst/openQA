# Copyright 2019 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::WebAPI::Controller::Admin::Influxdb;
use Mojo::Base 'Mojolicious::Controller';

use 5.018;

use OpenQA::Jobs::Constants;

sub _queue_sub_stats {
    my ($query, $state, $result) = @_;
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

sub _queue_output_measure {
    my ($url, $key, $tag, $states) = @_;
    my $line = "$key,url=$url";
    if ($tag) {
        $tag =~ s, ,\\ ,g;
        $line .= ",$tag";
    }
    $line .= " ";
    $line .= join(',', map { "$_=$states->{$_}i" } sort keys %$states);
    return $line . "\n";
}

# Renders a summary of jobs scheduled and running for monitoring
sub jobs {
    my $self = shift;

    my $result = {};

    my $schema = $self->schema;
    my $rs
      = $schema->resultset('Jobs')->search({state => OpenQA::Jobs::Constants::SCHEDULED, blocked_by_id => undef});
    _queue_sub_stats($rs, 'scheduled', $result);
    $rs = $schema->resultset('Jobs')
      ->search({state => OpenQA::Jobs::Constants::SCHEDULED, -not => {blocked_by_id => undef}});
    _queue_sub_stats($rs, 'blocked', $result);
    $rs = $schema->resultset('Jobs')->search({state => [OpenQA::Jobs::Constants::EXECUTION_STATES]});
    _queue_sub_stats($rs, 'running', $result);
    $rs = $schema->resultset('Jobs')->search(
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
    if ($result->{by_group}->{0}) {
        $result->{openqa_jobs_by_group}->{"group=No Group"} = $result->{by_group}->{0};
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

sub minion {
    my $self = shift;

    my $stats = $self->app->minion->stats;
    my $block_list = $self->app->config->{influxdb}->{ignored_failed_minion_jobs} || [];
    my $filter_jobs_num = $self->app->minion->jobs({states => ['failed'], tasks => $block_list})->total;

    my $jobs = {
        active => $stats->{active_jobs},
        delayed => $stats->{delayed_jobs},
        failed => $stats->{failed_jobs} - $filter_jobs_num,
        inactive => $stats->{inactive_jobs}};
    my $workers = {active => $stats->{active_workers}, inactive => $stats->{inactive_workers}};

    my $url = $self->app->config->{global}->{base_url} || $self->req->url->base->to_string;
    my $text = '';
    $text .= _queue_output_measure($url, 'openqa_minion_jobs', undef, $jobs);
    $text .= _queue_output_measure($url, 'openqa_minion_workers', undef, $workers);

    $self->render(text => $text);
}

1;
