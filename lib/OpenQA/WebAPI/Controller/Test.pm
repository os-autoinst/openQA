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
use OpenQA::Jobs::Constants;
use OpenQA::Schema::Result::Jobs;
use OpenQA::WebAPI::Controller::Developer;
use File::Basename;
use POSIX 'strftime';
use OpenQA::Utils qw(determine_web_ui_web_socket_url get_ws_status_only_url);

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
        state   => [OpenQA::Jobs::Constants::FINAL_STATES],
        match   => $match,
        scope   => $scope,
        assetid => $assetid,
        groupid => $groupid,
        limit   => $limit,
        idsonly => 1
    );
    $self->stash(jobs => $jobs);

    my $running = $self->db->resultset("Jobs")->complex_query(
        state   => [OpenQA::Jobs::Constants::EXECUTION_STATES],
        match   => $match,
        groupid => $groupid,
        assetid => $assetid
    );
    my @list;
    while (my $job = $running->next) {
        my $data = {
            job          => $job,
            result_stats => $job->result_stats,
            run_stat     => $job->running_modinfo(),
        };
        push @list, $data;
    }
    @list = sort {
        if ($b->{job} && $a->{job}) {
            $b->{job}->t_started <=> $a->{job}->t_started || $b->{job}->id <=> $a->{job}->id;
        }
        elsif ($b->{job}) {
            1;
        }
        elsif ($a->{job}) {
            -1;
        }
        else {
            0;
        }
    } @list;
    $self->stash(running => \@list);

    my $scheduled = $self->db->resultset("Jobs")->complex_query(
        state   => [OpenQA::Jobs::Constants::PRE_EXECUTION_STATES],
        match   => $match,
        groupid => $groupid,
        assetid => $assetid
    );
    #    $self->stash(blocked => $scheduled->search({-not => {blocked_by_id => undef}})->count);

    # @scheduled = sort {
    #     if ($b->{job} && $a->{job}) {
    #         $b->{job}->t_created <=> $a->{job}->t_created || $b->{job}->id <=> $a->{job}->id;
    #     }
    #     elsif ($b->{job}) {
    #         1;
    #     }
    #     elsif ($a->{job}) {
    #         -1;
    #     }
    #     else {
    #         0;
    #     }
    # }
    my @scheduled = $scheduled->search({})->all;
    @scheduled = sort { $b->t_created <=> $a->t_created || $b->id <=> $a->id } @scheduled;
    $self->stash(scheduled => \@scheduled);
}

sub prefetch_comment_counts {
    my ($self, $job_ids) = @_;

    my $comments = $self->db->resultset("Comments")->search(
        {'me.job_id' => {in => $job_ids}},
        {
            select   => ['job_id', {count => 'job_id', -as => 'count'}],
            group_by => [qw(job_id)]});
    my $comment_count;
    while (my $count = $comments->next) {
        $comment_count->{$count->job_id} = $count->get_column('count');
    }
    return $comment_count;
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

    # complete response
    my @list;
    my @jobs = $self->db->resultset("Jobs")->search(
        {'me.id' => {in => \@ids}},
        {
            columns => [
                qw(me.id MACHINE DISTRI VERSION FLAVOR ARCH BUILD TEST
                  state clone_id test result group_id t_finished
                  passed_module_count softfailed_module_count
                  failed_module_count skipped_module_count
                  )
            ],
            order_by => ['me.t_finished DESC, me.id DESC'],
            prefetch => [qw(children parents)],
        })->all;

    my $comment_count = $self->prefetch_comment_counts(\@ids);

    # need to use all as the order is too complex for a cursor
    for my $job (@jobs) {
        push(
            @list,
            {
                DT_RowId      => "job_" . $job->id,
                id            => $job->id,
                result_stats  => $job->result_stats,
                deps          => $job->dependencies,
                clone         => $job->clone_id,
                test          => $job->TEST . "@" . ($job->MACHINE // ''),
                distri        => $job->DISTRI // '',
                version       => $job->VERSION // '',
                flavor        => $job->FLAVOR // '',
                arch          => $job->ARCH // '',
                build         => $job->BUILD // '',
                testtime      => $job->t_finished . 'Z',
                result        => $job->result,
                group         => $job->group_id,
                comment_count => $comment_count->{$job->id} // 0,
                state         => $job->state
            });
    }
    $self->render(json => {data => \@list});
}

sub stash_module_list {
    my ($self) = @_;

    my $job_id = $self->param('testid') or return;
    my $job = $self->app->schema->resultset('Jobs')->search(
        {
            id => $job_id
        },
        {
            prefetch => qw(jobs_assets)
        }
      )->first
      or return;

    $self->stash(modlist => read_test_modules($job));
    return 1;
}

sub details {
    my ($self) = @_;

    $self->stash_module_list or return $self->reply->not_found;
    $self->render('test/details');
}

sub module_components {
    my ($self) = @_;

    $self->stash_module_list or return $self->reply->not_found;
    $self->render('test/module_components');
}

sub get_current_job {
    my ($self) = @_;

    return $self->reply->not_found if (!defined $self->param('testid'));

    my $job = $self->app->schema->resultset("Jobs")->search(
        {
            id => $self->param('testid')
        },
        {prefetch => qw(jobs_assets)})->first;
    return $job;
}

sub show {
    my ($self) = @_;
    my $job = $self->get_current_job;
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

    my $websocket_proxy = determine_web_ui_web_socket_url($job->id);
    $self->stash(ws_url => $websocket_proxy);
    my $rd = $job->result_dir();
    if ($rd) {    # saved anything
                  # result files box
        my $resultfiles = $job->test_resultfile_list;

        # uploaded logs box
        my $ulogs = $job->test_uploadlog_list;

        $self->stash(resultfiles => $resultfiles);
        $self->stash(ulogs       => $ulogs);
    }
    else {
        $self->stash(resultfiles => []);
        $self->stash(ulogs       => []);
    }

    # stash information for developer mode
    if ($job->state eq 'running') {
        my $current_user = $self->current_user;
        $self->stash(
            {
                ws_developer_url         => determine_web_ui_web_socket_url($job->id),
                ws_status_only_url       => get_ws_status_only_url($job->id),
                developer_session        => $job->developer_session,
                is_devel_mode_accessible => $current_user && $current_user->is_operator,
                current_user_id          => $current_user ? $current_user->id : 'undefined',
            });
    }

    $self->render('test/result');
}

sub job_next_previous_ajax {
    my ($self) = @_;

    my $job     = $self->get_current_job;
    my $jobid   = $job->id;
    my $p_limit = $self->param('previous_limit') // 400;
    my $n_limit = $self->param('next_limit') // 100;

    my $jobs_rs = $self->db->resultset("Jobs")->next_previous_jobs_query(
        $job, $jobid,
        previous_limit => $p_limit,
        next_limit     => $n_limit,
    );
    my (@jobs, @data);
    my $latest = 1;
    while (my $each = $jobs_rs->next) {
        # Output fetched job next and previous for future debug
        $self->app->log->debug("Fetched job next and previous "
              . $each->id . ": "
              . join('-', map { $each->get_column($_) } OpenQA::Schema::Result::Jobs::SCENARIO_WITH_MACHINE_KEYS));

        $latest = $each->id > $latest ? $each->id : $latest;
        push @jobs, $each;
        push(
            @data,
            {
                DT_RowId      => 'job_result_' . $each->id,
                id            => $each->id,
                name          => $each->name,
                distri        => $each->DISTRI,
                version       => $each->VERSION,
                build         => $each->BUILD,
                deps          => $each->dependencies,
                result        => $each->result,
                result_stats  => $each->result_stats,
                state         => $each->state,
                clone         => $each->clone_id,
                failedmodules => $each->failed_modules(),
                iscurrent     => $each->id == $jobid ? 1 : undef,
                islatest      => $each->id == $latest ? 1 : undef,
                finished      => $each->t_finished ? $each->t_finished->datetime() . 'Z' : undef,
                duration      => $each->t_started
                  && $each->t_finished ? $self->format_time_duration($each->t_finished - $each->t_started) : 0,
            });
    }
    my $labels = $self->_job_labels(\@jobs);
    for my $data (@data) {
        my $id         = $data->{id};
        my $bugs       = $labels->{$id}{bugs};
        my $bugdetails = $labels->{$id}{bugdetails};

        my (@bugs, @bug_urls, @bug_icons);
        for my $bug (sort { $b cmp $a } keys %$bugs) {
            push @bugs,      $bug;
            push @bug_urls,  $self->bugurl_for($bug);
            push @bug_icons, $self->bugicon_for($bug, $bugdetails->{$bug});
        }

        $data->{bugs}      = \@bugs;
        $data->{bug_urls}  = \@bug_urls;
        $data->{bug_icons} = \@bug_icons;
        $data->{label}     = $labels->{$id}{label};
        my $comments = $labels->{$id}{comments};
        if ($comments) {
            $data->{comments} = $comments;
            $data->{comment_icon} = $self->comment_icon($id, $comments);
        }
    }
    $self->render(
        json => {
            data => \@data
        });
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
    my %bugdetails;
    my $comments
      = $self->db->resultset('Comments')->search({job_id => {in => [map { $_->id } @$jobs]}}, {order_by => 'me.id'});
    # previous occurences of bug or label are overwritten here.
    while (my $comment = $comments->next()) {
        my $bugrefs = $comment->bugrefs;
        if (@$bugrefs) {
            my $bugs_of_job = ($labels{$comment->job_id}{bugs} //= {});
            for my $bug (@$bugrefs) {
                if (!exists $bugdetails{$bug}) {
                    $bugdetails{$bug} = OpenQA::Schema::Result::Bugs->get_bug($bug, $self->db);
                }
                $bugs_of_job->{$bug} = 1;
            }
            $labels{$comment->job_id}{bugdetails} = \%bugdetails;
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

    # prefetch the number of available labels for those jobs
    my $job_labels = $self->_job_labels($jobs);
    my @job_names = map { $_->TEST } @$jobs;

    # prefetch descriptions from test suites
    my %desc_args = (name => {in => \@job_names});
    my @descriptions = $self->db->resultset('TestSuites')->search(\%desc_args, {columns => [qw(name description)]});
    my %descriptions = map { $_->name => $_->description } @descriptions;

    my $todo = $self->param('todo');
    foreach my $job (@$jobs) {
        my $jobid  = $job->id;
        my $test   = $job->TEST;
        my $flavor = $job->FLAVOR || 'sweet';
        my $arch   = $job->ARCH || 'noarch';

        my $result;

        next
          if $self->param("failed_modules")
          && $job->result ne OpenQA::Jobs::Constants::FAILED;

        if ($job->state eq OpenQA::Jobs::Constants::DONE) {
            my $result_stats = $job->result_stats;
            my $overall      = $job->result;

            if ($todo) {
                # skip all jobs NOT needed to be labeled for the black certificate icon to show up
                next
                  if $job->result eq OpenQA::Jobs::Constants::PASSED
                  || $job_labels->{$jobid}{bugs}
                  || $job_labels->{$jobid}{label}
                  || ($job->result eq OpenQA::Jobs::Constants::SOFTFAILED
                    && ($job_labels->{$jobid}{label} || !$job->has_failed_modules));
            }


            $result = {
                passed     => $result_stats->{passed},
                unknown    => $result_stats->{none},
                failed     => $result_stats->{failed},
                overall    => $overall,
                jobid      => $jobid,
                state      => OpenQA::Jobs::Constants::DONE,
                failures   => $job->failed_modules(),
                bugs       => $job_labels->{$jobid}{bugs},
                bugdetails => $job_labels->{$jobid}{bugdetails},
                label      => $job_labels->{$jobid}{label},
                comments   => $job_labels->{$jobid}{comments},
            };
            $aggregated->{$overall}++;
        }
        elsif ($job->state eq OpenQA::Jobs::Constants::RUNNING) {
            next if $todo;
            $result = {
                state => OpenQA::Jobs::Constants::RUNNING,
                jobid => $jobid,
            };
            $aggregated->{running}++;
        }
        else {
            next if $todo;
            $result = {
                state    => $job->state,
                jobid    => $jobid,
                priority => $job->priority,
            };
            if ($job->state eq OpenQA::Jobs::Constants::SCHEDULED) {
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
        my $distri  = $job->DISTRI;
        my $version = $job->VERSION;
        $archs{$distri}{$version}{$flavor} //= [];
        push(@{$archs{$distri}{$version}{$flavor}}, $arch)
          unless (grep { $arch eq $_ } @{$archs{$distri}{$version}{$flavor}});

        # Populate %results by putting all distri, version, build, flavor into
        # levels of the hashes and just iterate over all levels in template.
        # if there is only one member on each level, do not output the key of
        # that level to resemble previous behaviour or maybe better, show it
        # in aggregation only
        $results{$distri}                           //= {};
        $results{$distri}{$version}                 //= {};
        $results{$distri}{$version}{$flavor}        //= {};
        $results{$distri}{$version}{$flavor}{$test} //= {};
        $results{$distri}{$version}{$flavor}{$test}{$arch} = $result;

        # add description
        $results{$distri}{$version}{$flavor}{$test}{description} //= $descriptions{$test =~ s/@.*//r};
    }
    return (\%archs, \%results, $aggregated);
}

# A generic query page showing test results in a configurable matrix
sub overview {
    my ($self) = @_;
    my ($search_args, $groups) = OpenQA::Utils::compose_job_overview_search_args($self);
    my %stash = (
        # build, version, distri are not mandatory and therefore not
        # necessarily come from the search args so they can be undefined.
        build   => $search_args->{build},
        version => $search_args->{version},
        distri  => $search_args->{distri},
        groups  => $groups,
    );
    my @latest_jobs = $self->db->resultset('Jobs')->complex_query(%$search_args)->latest_jobs;
    ($stash{archs}, $stash{results}, $stash{aggregated}) = $self->prepare_job_results(\@latest_jobs);
    $self->stash(%stash);
    $self->respond_to(
        json => {json     => \%stash},
        html => {template => 'test/overview'});
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
            next if ($job->result eq OpenQA::Jobs::Constants::OBSOLETED);
            $self->write_chunk(sprintf("Job %d: %s is %s\n", $job->id, $job->name, $job->result));
            my $modules = $job->modules->search(undef, {order_by => 'id'});
            while (my $m = $modules->next) {
                next if ($m->result eq OpenQA::Jobs::Constants::NONE);
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
