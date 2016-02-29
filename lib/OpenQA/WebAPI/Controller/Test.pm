# Copyright (C) 2015 SUSE Linux GmbH
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

package OpenQA::WebAPI::Controller::Test;
use strict;
use Mojo::Base 'Mojolicious::Controller';
use OpenQA::Utils;
use OpenQA::Schema::Result::Jobs;
use OpenQA::Scheduler::Scheduler qw/query_jobs/;
use File::Basename;
use POSIX qw/strftime/;
use JSON qw/decode_json/;

sub list {
    my $self = shift;

    my $match;
    if (defined($self->param('match'))) {
        $match = $self->param('match');
        $match =~ s/[^\w\[\]\{\}\(\),:.+*?\\\$^|-]//g;    # sanitize
    }

    my $scope = $self->param('scope');
    $scope = 'relevant' unless defined($scope);
    $self->param(scope => $scope);

    my $assetid = $self->param('assetid');
    my $groupid = $self->param('groupid');
    my $limit   = $self->param('limit') // 500;

    my $jobs = query_jobs(
        state   => 'done,cancelled',
        match   => $match,
        scope   => $scope,
        assetid => $assetid,
        groupid => $groupid,
        limit   => $limit,
        idsonly => 1
    );
    $self->stash(jobs => $jobs);

    my $running = query_jobs(
        state   => 'running,waiting',
        match   => $match,
        groupid => $groupid,
        assetid => $assetid
    );
    my $result_stats = OpenQA::Schema::Result::JobModules::job_module_stats($running);
    my @list;
    while (my $job = $running->next) {
        my $data = {
            job          => $job,
            result_stats => $result_stats->{$job->id},
            run_stat     => $job->running_modinfo(),
        };
        push @list, $data;
    }
    $self->stash(running => \@list);

    my $scheduled = query_jobs(
        state   => 'scheduled',
        match   => $match,
        groupid => $groupid,
        assetid => $assetid
    );
    $self->stash(scheduled => $scheduled);
}

sub list_ajax {
    my ($self) = @_;
    my $match;
    if (defined($self->param('match'))) {
        $match = $self->param('match');
        $match =~ s/[^\w\[\]\{\}\(\),:.+*?\\\$^|-]//g;    # sanitize
    }
    my $assetid = $self->param('assetid');
    my $groupid = $self->param('groupid');

    my @ids;
    # we have to seperate the initial loading and the reload
    if ($self->param('initial')) {
        @ids = map { scalar($_) } @{$self->every_param('jobs[]')};
    }
    else {
        my $scope = '';
        $scope = 'relevant' if $self->param('relevant') ne 'false';
        my $jobs = query_jobs(
            state   => 'done,cancelled',
            match   => $match,
            scope   => $scope,
            assetid => $assetid,
            groupid => $groupid,
            limit   => 500,
            idsonly => 1
        );
        while (my $j = $jobs->next) { push(@ids, $j->id); }
    }

    # job modules stats
    my $stats = OpenQA::Schema::Result::JobModules::job_module_stats(\@ids);

    # job settings
    my $settings;
    my $js = $self->db->resultset('JobSettings')->search(
        {
            job_id => {in => \@ids},
            key    => {in => [qw/MACHINE DISTRI VERSION FLAVOR ARCH BUILD/]},
        },
        {
            columns => [qw/key value job_id/],
        });
    while (my $s = $js->next) {
        $settings->{$s->job_id}->{$s->key} = $s->value;
    }

    # complete response
    my @list;
    my $jobs = $self->db->resultset("Jobs")->search(
        {'me.id' => {in => \@ids}},
        {
            columns  => [qw/me.id state clone_id test result group_id t_created/],
            order_by => ['me.id DESC'],
            prefetch => [qw/children parents/],
        });
    while (my $job = $jobs->next) {
        # job dependencies
        my %deps = (
            parents  => {Chained => [], Parallel => []},
            children => {Chained => [], Parallel => []});
        my $jp = $job->parents;
        while (my $s = $jp->next) {
            push(@{$deps{parents}->{$s->to_string}}, $s->parent_job_id);
        }
        my $jc = $job->children;
        while (my $s = $jc->next) {
            push(@{$deps{children}->{$s->to_string}}, $s->child_job_id);
        }
        my $js = $settings->{$job->id};

        my $data = {
            DT_RowId     => "job_" . $job->id,
            id           => $job->id,
            result_stats => $stats->{$job->id},
            deps         => \%deps,
            clone        => $job->clone_id,
            test         => $job->test . "@" . ($js->{MACHINE} // ''),
            distri  => $js->{DISTRI}  // '',
            version => $js->{VERSION} // '',
            flavor  => $js->{FLAVOR}  // '',
            arch    => $js->{ARCH}    // '',
            build   => $js->{BUILD}   // '',
            testtime => $job->t_created,
            result   => $job->result,
            group    => $job->group_id,
            state    => $job->state
        };
        push @list, $data;
    }
    $self->render(json => {data => \@list});
}

sub test_uploadlog_list($) {
    # get a list of uploaded logs
    my $testresdir = shift;
    my @filelist;
    for my $f (glob "$testresdir/ulogs/*") {
        $f =~ s#.*/##;
        push(@filelist, $f);
    }
    return @filelist;
}

sub test_resultfile_list($) {
    # get a list of existing resultfiles
    my ($testresdir) = @_;

    my @filelist = qw(video.ogv vars.json backend.json serial0.txt autoinst-log.txt);
    my @filelist_existing;
    for my $f (@filelist) {
        if (-e "$testresdir/$f") {
            push(@filelist_existing, $f);
        }
    }
    return @filelist_existing;
}

sub read_test_modules {
    my ($job) = @_;

    my $testresultdir = $job->result_dir();
    return [] unless $testresultdir;

    my @modlist;

    for my $module (OpenQA::Schema::Result::JobModules::job_modules($job)) {
        my $name = $module->name();
        # add link to $testresultdir/$name*.png via png CGI
        my @details;

        my $num = 1;

        for my $step (@{$module->details}) {
            $step->{num} = $num++;
            push(@details, $step);
        }

        push(
            @modlist,
            {
                name         => $module->name,
                result       => $module->result,
                details      => \@details,
                soft_failure => $module->soft_failure,
                milestone    => $module->milestone,
                important    => $module->important,
                fatal        => $module->fatal
            });
    }

    return \@modlist;
}

sub show {
    my ($self) = @_;

    return $self->reply->not_found if (!defined $self->param('testid'));

    my $job = $self->app->schema->resultset("Jobs")->search(
        {
            id => $self->param('testid')
        },
        {prefetch => qw/jobs_assets/})->first;

    return $self->reply->not_found unless $job;

    my @scenario_keys = qw/DISTRI VERSION FLAVOR ARCH TEST/;
    my $scenario = join('-', map { $job->settings_hash->{$_} } @scenario_keys);

    $self->stash(testname => $job->settings_hash->{NAME});
    $self->stash(distri   => $job->settings_hash->{DISTRI});
    $self->stash(version  => $job->settings_hash->{VERSION});
    $self->stash(build    => $job->settings_hash->{BUILD});
    $self->stash(scenario => $scenario);

    #  return $self->reply->not_found unless (-e $self->stash('resultdir'));

    # If it's running
    if ($job->state =~ /^(?:running|waiting)$/) {
        $self->stash(worker => $job->worker);
        $self->stash(job    => $job);
        $self->stash('backend_info', decode_json($job->backend_info || '{}'));
        $self->render('test/running');
        return;
    }

    my $clone_of = $self->db->resultset("Jobs")->find({clone_id => $job->id});

    my $modlist = read_test_modules($job);
    $self->stash(job      => $job);
    $self->stash(clone_of => $clone_of);
    $self->stash(modlist  => $modlist);

    my $rd = $job->result_dir();
    if ($rd) {    # saved anything
                  # result files box
        my @resultfiles = test_resultfile_list($job->result_dir());

        # uploaded logs box
        my @ulogs = test_uploadlog_list($job->result_dir());

        $self->stash(resultfiles => \@resultfiles);
        $self->stash(ulogs       => \@ulogs);
    }
    else {
        $self->stash(resultfiles => []);
        $self->stash(ulogs       => []);
    }

    # search for previous jobs
    my @conds;
    push(@conds, {'me.state'  => 'done'});
    push(@conds, {'me.result' => {-not_in => [OpenQA::Schema::Result::Jobs::INCOMPLETE_RESULTS]}});
    push(@conds, {id          => {'<', $job->id}});
    my %js_settings = map { $_ => $job->settings_hash->{$_} } @scenario_keys;
    my $subquery = $self->db->resultset("JobSettings")->query_for_settings(\%js_settings);
    push(@conds, {'me.id' => {-in => $subquery->get_column('job_id')->as_query}});

    my $limit_previous = $self->param('limit_previous') // 10;    # arbitrary limit of previous results to show
    my %attrs = (
        rows     => $limit_previous,
        order_by => ['me.id DESC']);
    my $previous_jobs_rs = $self->db->resultset("Jobs")->search({-and => \@conds}, \%attrs);
    my @previous_jobs;
    while (my $prev = $previous_jobs_rs->next) {
        $self->app->log->debug("Previous result job " . $prev->id . ": " . join('-', map { $prev->settings_hash->{$_} } @scenario_keys));
        push(@previous_jobs, $prev);
    }
    my $job_labels = $self->_job_labels(\@previous_jobs);

    $self->stash(previous        => \@previous_jobs);
    $self->stash(previous_labels => $job_labels);
    $self->stash(limit_previous  => $limit_previous);

    $self->render('test/result');
}

sub _calculate_preferred_machines {
    my ($jobs) = @_;
    my %machines;

    foreach my $job (@$jobs) {
        my $sh = $job->settings_hash;
        next unless $sh->{MACHINE};
        $machines{$sh->{ARCH}} ||= {};
        $machines{$sh->{ARCH}}->{$sh->{MACHINE}}++;
    }
    my $pms = {};
    for my $arch (keys %machines) {
        my $max = 0;
        for my $machine (keys %{$machines{$arch}}) {
            if ($machines{$arch}->{$machine} > $max) {
                $max = $machines{$arch}->{$machine};
                $pms->{$arch} = $machine;
            }
        }
    }
    return $pms;
}

sub _job_labels {
    my ($self, $jobs) = @_;

    my %labels;
    my $c = $self->db->resultset("Comments")->search({job_id => {in => [map { $_->id } @$jobs]}});
    # previous occurences of bug or label are overwritten here so the
    # behaviour for multiple bugs or label references within one job is
    # undefined.
    while (my $comment = $c->next()) {
        if ($comment->text =~ /\b[^t]+#\d+\b/) {
            $self->app->log->debug('found bug ticket reference ' . $& . ' for job ' . $comment->job_id);
            $labels{$comment->job_id}{bug} = $&;
        }
        elsif ($comment->text =~ /\blabel:(\w+)\b/) {
            $self->app->log->debug('found label ' . $1 . ' for job ' . $comment->job_id);
            $labels{$comment->job_id}{label} = $1;
        }
        else {
            $labels{$comment->job_id}{comments}++;
        }
    }
    return \%labels;
}

# Custom action enabling the openSUSE Release Team
# to see the quality at a glance
sub overview {
    my $self       = shift;
    my $validation = $self->validation;
    for my $arg (qw/distri version/) {
        $validation->required($arg);
    }
    if ($validation->has_error) {
        return $self->render(text => 'Missing parameters', status => 404);
    }

    my %search_args;
    my $group;
    for my $arg (qw/distri version flavor build/) {
        next unless defined $self->param($arg);
        $search_args{$arg} = $self->param($arg);
    }

    if ($self->param('groupid') or $self->param('group')) {
        my $search_term = $self->param('groupid') ? $self->param('groupid') : {name => $self->param('group')};
        $group = $self->db->resultset("JobGroups")->find($search_term);
        return $self->reply->not_found if (!$group);
        $search_args{groupid} = $group->id;
    }

    if (!$search_args{build}) {
        $search_args{build} = $self->db->resultset("Jobs")->latest_build(%search_args);
    }
    $search_args{scope} = 'current';

    my @configs;
    my %archs;
    my %results;
    my $aggregated = {none => 0, passed => 0, failed => 0, incomplete => 0, scheduled => 0, running => 0, unknown => 0};

    # Forward all query parameters to query_jobs to allow specifying additional
    # query parameters which are then properly shown on the overview.
    my $req_params = $self->req->params->to_hash;
    %search_args = (%search_args, %$req_params);
    my @latest_jobs        = query_jobs(%search_args)->latest_jobs;
    my $preferred_machines = _calculate_preferred_machines(\@latest_jobs);
    my @latest_jobs_ids    = map { $_->id } @latest_jobs;
    my $all_result_stats   = OpenQA::Schema::Result::JobModules::job_module_stats(\@latest_jobs_ids);

    # prefetch the number of available labels for those jobs
    my $job_labels = $self->_job_labels(\@latest_jobs);

    foreach my $job (@latest_jobs) {
        my $settings = $job->settings_hash;
        my $test     = $job->test;
        my $flavor   = $settings->{FLAVOR} || 'sweet';
        my $arch     = $settings->{ARCH} || 'noarch';

        my $result;
        if ($job->state eq 'done') {
            my $result_stats = $all_result_stats->{$job->id};
            my $overall      = $job->result;
            if ($job->result eq "passed" && $result_stats->{dents}) {
                $overall = "softfail";
            }
            $result = {
                passed   => $result_stats->{passed},
                unknown  => $result_stats->{unk},
                failed   => $result_stats->{failed},
                dents    => $result_stats->{dents},
                overall  => $overall,
                jobid    => $job->id,
                state    => "done",
                failures => $job->failed_modules_with_needles(),
                bug      => $job_labels->{$job->id}{bug},
                label    => $job_labels->{$job->id}{label},
                comments => $job_labels->{$job->id}{comments},
            };
            $aggregated->{$overall}++;
        }
        elsif ($job->state eq 'running') {
            $result = {
                state => "running",
                jobid => $job->id,
            };
            $aggregated->{running}++;
        }
        else {
            $result = {
                state    => $job->state,
                jobid    => $job->id,
                priority => $job->priority,
            };
            if ($job->state eq 'scheduled') {
                $aggregated->{scheduled}++;
            }
            else {
                $aggregated->{none}++;
            }
        }

        # Populate @configs and %archs
        if ($settings->{MACHINE} && $preferred_machines->{$settings->{ARCH}} && $preferred_machines->{$settings->{ARCH}} ne $settings->{MACHINE}) {
            $test .= "@" . $settings->{MACHINE};
        }
        push(@configs, $test) unless (grep { $test eq $_ } @configs);
        $archs{$flavor} = [] unless $archs{$flavor};
        push(@{$archs{$flavor}}, $arch) unless (grep { $arch eq $_ } @{$archs{$flavor}});

        # Populate %results
        $results{$test} = {} unless $results{$test};
        $results{$test}{$flavor} = {} unless $results{$test}{$flavor};
        $results{$test}{$flavor}{$arch} = $result;
    }

    # Sorting everything
    my @types = keys %archs;
    @types   = sort @types;
    @configs = sort @configs;
    for my $flavor (@types) {
        my @sorted = sort(@{$archs{$flavor}});
        $archs{$flavor} = \@sorted;
    }

    $self->stash(
        build      => $search_args{build},
        version    => $search_args{version},
        distri     => $search_args{distri},
        group      => $group,
        configs    => \@configs,
        types      => \@types,
        archs      => \%archs,
        results    => \%results,
        aggregated => $aggregated
    );
}

sub add_comment {
    my ($self) = @_;

    $self->validation->required('text');

    my $job = $self->app->schema->resultset("Jobs")->find($self->param('testid'));
    return $self->reply->not_found unless $job;

    my $rs = $job->comments->create(
        {
            text    => $self->param('text'),
            user_id => $self->current_user->id,
        });
    $self->emit_event('openqa_user_comment', {id => $rs->id});
    $self->flash('info', 'Comment added');
    return $self->redirect_to('test');
}

1;
# vim: set sw=4 et:
