# Copyright (C) 2015-2016 SUSE LLC
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
use File::Basename;
use POSIX 'strftime';
use JSON 'decode_json';

sub referer_check {
    my ($self) = @_;
    return $self->reply->not_found if (!defined $self->param('testid'));
    my $referer = $self->req->headers->header('Referer') // '';
    if ($referer) {
        mark_job_linked($self->param('testid'), $referer);
    }
    return 1;
}

sub list {
    my ($self) = @_;

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

    my $jobs = $self->db->resultset("Jobs")->complex_query(
        state   => 'done,cancelled',
        match   => $match,
        scope   => $scope,
        assetid => $assetid,
        groupid => $groupid,
        limit   => $limit,
        idsonly => 1
    );
    $self->stash(jobs => $jobs);

    my $running = $self->db->resultset("Jobs")->complex_query(
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
    @list = sort { $b->{job}->t_started <=> $a->{job}->t_started || $b->{job}->id <=> $a->{job}->id } @list;
    $self->stash(running => \@list);

    my @scheduled = $self->db->resultset("Jobs")->complex_query(
        state   => 'scheduled',
        match   => $match,
        groupid => $groupid,
        assetid => $assetid
    )->all;
    @scheduled = sort { $b->t_created <=> $a->t_created || $b->id <=> $a->id } @scheduled;
    $self->stash(scheduled => \@scheduled);
}

sub list_ajax {
    my ($self)  = @_;
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
        my $jobs = $self->db->resultset("Jobs")->complex_query(
            state   => 'done,cancelled',
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

    # complete response
    my @list;
    my @jobs = $self->db->resultset("Jobs")->search(
        {'me.id' => {in => \@ids}},
        {
            columns =>
              [qw(me.id MACHINE DISTRI VERSION FLAVOR ARCH BUILD TEST state clone_id test result group_id t_finished)],
            order_by => ['me.t_finished DESC, me.id DESC'],
            prefetch => [qw(children parents)],
        })->all;
    # need to use all as the order is too complex for a cursor
    for my $job (@jobs) {
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

        my $data = {
            DT_RowId     => "job_" . $job->id,
            id           => $job->id,
            result_stats => $stats->{$job->id},
            deps         => \%deps,
            clone        => $job->clone_id,
            test         => $job->TEST . "@" . ($job->MACHINE // ''),
            distri  => $job->DISTRI  // '',
            version => $job->VERSION // '',
            flavor  => $job->FLAVOR  // '',
            arch    => $job->ARCH    // '',
            build   => $job->BUILD   // '',
            testtime => $job->t_finished,
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

    my @filelist = qw(video.ogv vars.json backend.json serial0.txt autoinst-log.txt serial_terminal.txt);
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

    my $category;
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
                name      => $module->name,
                result    => $module->result,
                details   => \@details,
                milestone => $module->milestone,
                important => $module->important,
                fatal     => $module->fatal
            });

        if (!$category || $category ne $module->category) {
            $category = $module->category;
            $modlist[-1]->{category} = $category;
        }

    }

    return \@modlist;
}

sub details {
    my ($self) = @_;

    return $self->reply->not_found if (!defined $self->param('testid'));

    my $job = $self->app->schema->resultset("Jobs")->search(
        {
            id => $self->param('testid')
        },
        {prefetch => qw(jobs_assets)})->first;
    return $self->reply->not_found unless $job;

    my $modlist = read_test_modules($job);
    $self->stash(modlist => $modlist);

    $self->render('test/details');
}

sub show {
    my ($self) = @_;

    return $self->reply->not_found if (!defined $self->param('testid'));

    my $job = $self->app->schema->resultset("Jobs")->search(
        {
            id => $self->param('testid')
        },
        {prefetch => qw(jobs_assets)})->first;
    return $self->_show($job);
}

sub _show {
    my ($self, $job) = @_;
    return $self->reply->not_found unless $job;

    $self->stash(
        {
            testname        => $job->name,
            distri          => $job->DISTRI,
            version         => $job->VERSION,
            build           => $job->BUILD,
            scenario        => $job->scenario,
            worker          => $job->worker,
            assigned_worker => $job->assigned_worker,
        });

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
    for my $key (OpenQA::Schema::Result::Jobs::SCENARIO_WITH_MACHINE_KEYS) {
        push(@conds, {"me.$key" => $job->get_column($key)});
    }
    # arbitrary limit of previous results to show
    my $limit_previous = $self->param('limit_previous') // 10;
    my %attrs = (
        rows     => $limit_previous,
        order_by => ['me.id DESC']);
    my $previous_jobs_rs = $self->db->resultset("Jobs")->search({-and => \@conds}, \%attrs);
    my @previous_jobs;
    while (my $prev = $previous_jobs_rs->next) {
        $self->app->log->debug("Previous result job "
              . $prev->id . ": "
              . join('-', map { $prev->get_column($_) } OpenQA::Schema::Result::Jobs::SCENARIO_WITH_MACHINE_KEYS));
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
        next unless $job->MACHINE;
        $machines{$job->ARCH} ||= {};
        $machines{$job->ARCH}->{$job->MACHINE}++;
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
    my $c
      = $self->db->resultset("Comments")->search({job_id => {in => [map { $_->id } @$jobs]}}, {order_by => 'me.id'});
    # previous occurences of bug or label are overwritten here.
    while (my $comment = $c->next()) {
        my $bugrefs = $comment->bugrefs;
        if (@$bugrefs) {
            push(@{$labels{$comment->job_id}{bugs} //= []}, @$bugrefs);
            $self->app->log->debug(
                'Found bug ticket reference ' . join(' ', @$bugrefs) . ' for job ' . $comment->job_id);
        }
        elsif (my $label = $comment->label) {
            $self->app->log->debug('Found label ' . $label . ' for job ' . $comment->job_id);
            $labels{$comment->job_id}{label} = $label;
        }
        else {
            $labels{$comment->job_id}{comments}++;
        }
    }
    return \%labels;
}

# Take an job objects arrayref and prepare data structures for 'overview'
sub prepare_job_results {
    my ($self, $jobs) = @_;
    my %archs;
    my %results;
    my $aggregated = {none => 0, passed => 0, failed => 0, incomplete => 0, scheduled => 0, running => 0, unknown => 0};
    my $preferred_machines = _calculate_preferred_machines($jobs);
    my @latest_jobs_ids    = map { $_->id } @{$jobs};
    my $all_result_stats   = OpenQA::Schema::Result::JobModules::job_module_stats(\@latest_jobs_ids);

    # prefetch the number of available labels for those jobs
    my $job_labels = $self->_job_labels($jobs);
    my @job_names = map { $_->TEST } @$jobs;

    # prefetch descriptions from test suites
    my %desc_args = (name => {in => \@job_names});
    my @descriptions = $self->db->resultset("TestSuites")->search(\%desc_args, {columns => [qw(name description)]});
    my %descriptions = map { $_->name => $_->description } @descriptions;

    foreach my $job (@$jobs) {
        my $test   = $job->TEST;
        my $flavor = $job->FLAVOR || 'sweet';
        my $arch   = $job->ARCH || 'noarch';

        my $result;
        if ($job->state eq 'done') {
            my $result_stats = $all_result_stats->{$job->id};
            my $overall      = $job->result;
            if ($job->result eq "passed") {
                next if $self->param('todo');
            }
            if ($self->param('todo')) {
                next if $job_labels->{$job->id}{bugs} || $job_labels->{$job->id}{label};
            }
            $result = {
                passed   => $result_stats->{passed},
                unknown  => $result_stats->{unk},
                failed   => $result_stats->{failed},
                overall  => $overall,
                jobid    => $job->id,
                state    => 'done',
                failures => $job->failed_modules(),
                bugs     => $job_labels->{$job->id}{bugs},
                label    => $job_labels->{$job->id}{label},
                comments => $job_labels->{$job->id}{comments},
            };
            $aggregated->{$overall}++;
        }
        elsif ($job->state eq 'running') {
            next if $self->param('todo');
            $result = {
                state => "running",
                jobid => $job->id,
            };
            $aggregated->{running}++;
        }
        else {
            next if $self->param('todo');
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

        # Populate %archs
        if (   $job->MACHINE
            && $preferred_machines->{$job->ARCH}
            && $preferred_machines->{$job->ARCH} ne $job->MACHINE)
        {
            $test .= "@" . $job->MACHINE;
        }
        # poor mans set
        $archs{$flavor} //= [];
        push(@{$archs{$flavor}}, $arch) unless (grep { $arch eq $_ } @{$archs{$flavor}});

        # Populate %results
        $results{$test}                   //= {};
        $results{$test}{description}      //= $descriptions{$test};
        $results{$test}{flavors}          //= {};
        $results{$test}{flavors}{$flavor} //= {};
        $results{$test}{flavors}{$flavor}{$arch} = $result;
    }
    return (\%archs, \%results, $aggregated);
}

# A generic query page showing test results in a configurable matrix
sub overview {
    my ($self) = @_;
    my $validation = $self->validation;
    for my $arg (qw(distri version)) {
        $validation->required($arg);
    }
    if ($validation->has_error) {
        return $self->render(text => 'Missing parameters', status => 404);
    }

    my %search_args;
    my @groups;
    for my $arg (qw(distri version flavor build)) {
        next unless defined $self->param($arg);
        $search_args{$arg} = $self->param($arg);
    }

    # By 'every_param' we make sure to use multiple values for groupid and
    # group at the same time as a logical or, i.e. all specified groups are
    # returned
    if ($self->param('groupid') or $self->param('group')) {
        my @group_id_search   = map { {id   => $_} } @{$self->every_param('groupid')};
        my @group_name_search = map { {name => $_} } @{$self->every_param('group')};
        my @search_terms = (@group_id_search, @group_name_search);
        @groups = $self->db->resultset("JobGroups")->search(\@search_terms)->all;
    }

    if (!$search_args{build}) {
        if (@groups > 1) {
            return $self->render(text => 'Specify a build when you want to lookup multiple groups', status => 404);
        }
        elsif (@groups == 1) {
            $search_args{groupid} = $groups[0]->id;
        }
        $search_args{build} = $self->db->resultset("Jobs")->latest_build(%search_args);
    }
    $search_args{scope} = 'current';

    # Forward all query parameters to jobs query to allow specifying additional
    # query parameters which are then properly shown on the overview.
    my $req_params = $self->req->params->to_hash;
    %search_args = (%search_args, %$req_params);
    my @latest_jobs = $self->db->resultset("Jobs")->complex_query(%search_args)->latest_jobs;
    my ($archs, $results, $aggregated) = $self->prepare_job_results(\@latest_jobs);
    # Sorting everything
    my @types = keys %$archs;
    @types = sort @types;
    for my $flavor (@types) {
        my @sorted = sort(@{$archs->{$flavor}});
        $archs->{$flavor} = \@sorted;
    }

    $self->stash(
        build      => $search_args{build},
        version    => $search_args{version},
        distri     => $search_args{distri},
        groups     => \@groups,
        types      => \@types,
        archs      => $archs,
        results    => $results,
        aggregated => $aggregated
    );
}

sub latest {
    my ($self) = @_;
    my %search_args = (limit => 1);
    for my $arg (OpenQA::Schema::Result::Jobs::SCENARIO_WITH_MACHINE_KEYS) {
        my $key = lc $arg;
        next unless defined $self->param($key);
        $search_args{$key} = $self->param($key);
    }
    my $job = $self->db->resultset("Jobs")->complex_query(%search_args)->first;
    return $self->render(text => 'No matching job found', status => 404) unless $job;
    $self->stash(testid => $job->id);
    return $self->_show($job);
}

sub export {
    my ($self) = @_;
    $self->res->headers->content_type('text/plain');

    my @groups = $self->app->schema->resultset("JobGroups")->search(undef, {order_by => 'name'});

    for my $group (@groups) {
        $self->write_chunk(sprintf("Jobs of Group '%s'\n", $group->name));
        my @conds;
        if ($self->param('from')) {
            push(@conds, {id => {'>=' => $self->param('from')}});
        }
        if ($self->param('to')) {
            push(@conds, {id => {'<' => $self->param('to')}});
        }
        my $jobs = $group->jobs->search({-and => \@conds}, {order_by => 'id'});
        while (my $job = $jobs->next) {
            next if ($job->result eq OpenQA::Schema::Result::Jobs::OBSOLETED);
            $self->write_chunk(sprintf("Job %d: %s is %s\n", $job->id, $job->name, $job->result));
            my $modules = $job->modules->search(undef, {order_by => 'id'});
            while (my $m = $modules->next) {
                next if ($m->result eq OpenQA::Schema::Result::Jobs::NONE);
                $self->write_chunk(sprintf("  %s/%s: %s\n", $m->category, $m->name, $m->result));
            }
        }
        $self->write_chunk("\n\n");
    }
    $self->finish('END');
}

sub module_fails {
    my ($self) = @_;

    unless (defined $self->param('testid') and defined $self->param('moduleid')) {
        return $self->reply->not_found;
    }

    my $module = $self->app->schema->resultset("JobModules")->search(
        {
            job_id => $self->param('testid'),
            name   => $self->param('moduleid')})->first;

    my @needles;

    my $counter           = 0;
    my $first_failed_step = 0;
    for my $detail (@{$module->details}) {
        $counter++;
        next unless $detail->{result} eq 'fail';
        if ($first_failed_step == 0) {
            $first_failed_step = $counter;
        }
        for my $needle (@{$detail->{needles}}) {
            push @needles, $needle->{name};
        }
    }

    # Fallback to first step
    if ($first_failed_step == 0) {
        $first_failed_step = 1;
    }

    $self->render(
        json => {
            first_failed_step => $first_failed_step,
            failed_needles    => \@needles
        });
}

1;
# vim: set sw=4 et:
