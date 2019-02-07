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
use Mojo::Base 'Mojolicious::Controller';

use OpenQA::Utils;
use OpenQA::Jobs::Constants;
use OpenQA::Schema::Result::Jobs;
use OpenQA::Schema::Result::JobDependencies;
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

sub get_match_param {
    my ($self) = @_;

    my $match;
    if (defined($self->param('match'))) {
        $match = $self->param('match');
        $match =~ s/[^\w\[\]\{\}\(\),:.+*?\\\$^|-]//g;    # sanitize
    }
    return $match;
}

sub list_ajax {
    my ($self) = @_;

    my $scope = ($self->param('relevant') ne 'false' ? 'relevant' : '');
    my @jobs  = $self->db->resultset('Jobs')->complex_query(
        state    => [OpenQA::Jobs::Constants::FINAL_STATES],
        scope    => $scope,
        match    => $self->get_match_param,
        assetid  => $self->param('assetid'),
        groupid  => $self->param('groupid'),
        limit    => ($self->param('limit') // 500),
        order_by => [{-desc => 'me.t_finished'}, {-desc => 'me.id'}],
        columns  => [
            qw(id MACHINE DISTRI VERSION FLAVOR ARCH BUILD TEST
              state clone_id result group_id t_finished
              passed_module_count softfailed_module_count
              failed_module_count skipped_module_count
              externally_skipped_module_count
              )
        ],
        prefetch => [qw(children parents)],
    )->all;

    # need to use all as the order is too complex for a cursor
    my $comment_count = $self->prefetch_comment_counts([map { $_->id } @jobs]);
    my @list;
    for my $job (@jobs) {
        my $job_id = $job->id;
        push(
            @list,
            {
                DT_RowId      => 'job_' . $job_id,
                id            => $job_id,
                result_stats  => $job->result_stats,
                deps          => $job->dependencies,
                clone         => $job->clone_id,
                test          => $job->TEST . '@' . ($job->MACHINE // ''),
                distri        => $job->DISTRI // '',
                version       => $job->VERSION // '',
                flavor        => $job->FLAVOR // '',
                arch          => $job->ARCH // '',
                build         => $job->BUILD // '',
                testtime      => ($job->t_finished // '') . 'Z',
                result        => $job->result,
                group         => $job->group_id,
                comment_count => $comment_count->{$job_id} // 0,
                state         => $job->state,
            });
    }
    $self->render(json => {data => \@list});
}

sub list_running_ajax {
    my ($self) = @_;

    my $running = $self->db->resultset('Jobs')->complex_query(
        state    => [OpenQA::Jobs::Constants::EXECUTION_STATES],
        match    => $self->get_match_param,
        groupid  => $self->param('groupid'),
        assetid  => $self->param('assetid'),
        order_by => [{-desc => 'me.t_started'}, {-desc => 'me.id'}, {-asc => 'modules.id'},],
        columns  => [
            qw(id MACHINE DISTRI VERSION FLAVOR ARCH BUILD TEST
              state result clone_id group_id t_started blocked_by_id priority
              )
        ],
        prefetch => [qw(modules)],
    );

    my @running;
    while (my $job = $running->next) {
        my $job_id = $job->id;
        push(
            @running,
            {
                DT_RowId => 'job_' . $job_id,
                id       => $job_id,
                clone    => $job->clone_id,
                test     => $job->TEST . '@' . ($job->MACHINE // ''),
                distri   => $job->DISTRI // '',
                version  => $job->VERSION // '',
                flavor   => $job->FLAVOR // '',
                arch     => $job->ARCH // '',
                build    => $job->BUILD // '',
                testtime => ($job->t_started // '') . 'Z',
                group    => $job->group_id,
                state    => $job->state,
                progress => $job->progress_info,
            });
    }
    $self->render(json => {data => \@running});
}

sub list_scheduled_ajax {
    my ($self) = @_;

    my $scheduled = $self->db->resultset('Jobs')->complex_query(
        state    => [OpenQA::Jobs::Constants::PRE_EXECUTION_STATES],
        match    => $self->get_match_param,
        groupid  => $self->param('groupid'),
        assetid  => $self->param('assetid'),
        order_by => [{-desc => 'me.t_created'}, {-desc => 'me.id'}],
        columns  => [
            qw(id MACHINE DISTRI VERSION FLAVOR ARCH BUILD TEST
              state clone_id result group_id t_created
              blocked_by_id priority
              )
        ],
    );

    my @scheduled;
    while (my $job = $scheduled->next) {
        my $job_id = $job->id;
        push(
            @scheduled,
            {
                DT_RowId      => 'job_' . $job_id,
                id            => $job_id,
                clone         => $job->clone_id,
                test          => $job->TEST . '@' . ($job->MACHINE // ''),
                distri        => $job->DISTRI // '',
                version       => $job->VERSION // '',
                flavor        => $job->FLAVOR // '',
                arch          => $job->ARCH // '',
                build         => $job->BUILD // '',
                testtime      => $job->t_created . 'Z',
                group         => $job->group_id,
                state         => $job->state,
                blocked_by_id => $job->blocked_by_id,
                prio          => $job->priority,
            });
    }
    $self->render(json => {data => \@scheduled});
}

sub stash_module_list {
    my ($self) = @_;

    my $job_id = $self->param('testid') or return;
    my $job    = $self->app->schema->resultset('Jobs')->search(
        {
            id => $job_id
        },
        {
            prefetch => qw(jobs_assets)
        }
      )->first
      or return;

    my $test_modules = read_test_modules($job);
    $self->stash(modlist => ($test_modules ? $test_modules->{modules} : []));
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

    my $test_modules    = read_test_modules($job);
    my $worker          = $job->worker;
    my $clone_of        = $self->db->resultset('Jobs')->find({clone_id => $job->id});
    my $websocket_proxy = determine_web_ui_web_socket_url($job->id);

    $self->stash(
        {
            job                     => $job,
            testname                => $job->name,
            distri                  => $job->DISTRI,
            version                 => $job->VERSION,
            build                   => $job->BUILD,
            scenario                => $job->scenario_name,
            worker                  => $worker,
            assigned_worker         => $job->assigned_worker,
            show_dependencies       => !defined($job->clone_id) && $job->has_dependencies,
            clone_of                => $clone_of,
            modlist                 => ($test_modules ? $test_modules->{modules} : []),
            ws_url                  => $websocket_proxy,
            has_parser_text_results => $test_modules->{has_parser_text_results},
        });

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
        my $worker_vnc   = ($worker ? $worker->host . ':' . (90 + $worker->instance) : undef);
        $self->stash(
            {
                ws_developer_url         => determine_web_ui_web_socket_url($job->id),
                ws_status_only_url       => get_ws_status_only_url($job->id),
                developer_session        => $job->developer_session,
                is_devel_mode_accessible => $current_user && $current_user->is_operator,
                current_user_id          => $current_user ? $current_user->id : 'undefined',
                worker_vnc               => $worker_vnc,
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

        my @bugs;
        for my $bug (sort { $b cmp $a } keys %$bugs) {
            push @bugs,
              {
                bug   => $bug,
                url   => $self->bugurl_for($bug),
                icon  => $self->bugicon_for($bug, $bugdetails->{$bug}),
                title => $self->bugtitle_for($bug, $bugdetails->{$bug})};
        }

        $data->{bugs}  = \@bugs;
        $data->{label} = $labels->{$id}{label};
        my $comments = $labels->{$id}{comments};
        if ($comments) {
            $data->{comments}     = $comments;
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

    # read parameter for additional filtering
    my $failed_modules = OpenQA::Utils::param_hash($self, 'failed_modules');
    my $states         = OpenQA::Utils::param_hash($self, 'state');
    my $results        = OpenQA::Utils::param_hash($self, 'result');
    my $archs          = OpenQA::Utils::param_hash($self, 'arch');

    # prefetch the number of available labels for those jobs
    my $job_labels = $self->_job_labels($jobs);
    my @job_names  = map { $_->TEST } @$jobs;

    # prefetch descriptions from test suites
    my %desc_args = (name => {in => \@job_names});
    my @descriptions = $self->db->resultset('TestSuites')->search(\%desc_args, {columns => [qw(name description)]});
    my %descriptions = map { $_->name => $_->description } @descriptions;

    my $todo = $self->param('todo');
    foreach my $job (@$jobs) {
        next if $states         && !$states->{$job->state};
        next if $results        && !$results->{$job->result};
        next if $archs          && !$archs->{$job->ARCH};
        next if $failed_modules && $job->result ne OpenQA::Jobs::Constants::FAILED;

        my $jobid  = $job->id;
        my $test   = $job->TEST;
        my $flavor = $job->FLAVOR || 'sweet';
        my $arch   = $job->ARCH || 'noarch';
        my $result;
        if ($job->state eq OpenQA::Jobs::Constants::DONE) {
            my $actually_failed_modules = $job->failed_modules;
            next
              unless !$failed_modules
              || OpenQA::Utils::any_array_item_contained_by_hash($actually_failed_modules, $failed_modules);

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
                failures   => $actually_failed_modules,
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

    # determine distribution/version from job results if not explicitely specified via search args
    my @distris     = keys %{$stash{results}};
    my $only_distri = scalar @distris == 1;
    if (!defined $stash{distri} && $only_distri) {
        my $distri = $stash{distri} = $distris[0];
        if (!defined $stash{version}) {
            my @versions = keys %{$stash{results}->{$distri}};
            $stash{version} = $versions[0] if (scalar @versions == 1);
        }
    }

    # determine summary name for "Overall Summary of ..."
    my $summary_name;
    if (@$groups) {
        $summary_name = join(', ',
            map { $self->link_to($_->name => $self->url_for('group_overview', groupid => $_->id)) } @$groups);
    }
    else {
        my @variables = ($stash{distri}, $stash{version});
        my @formatted_parts;
        for my $part (@variables) {
            $part = $part->{-in} if (ref $part eq 'HASH');
            next unless $part;

            if (ref $part eq 'ARRAY') {
                push(@formatted_parts, join('/', @$part));
            }
            elsif (ref $part ne 'HASH') {
                push(@formatted_parts, $part);
            }
        }
        $summary_name = join(' ', @formatted_parts) if (@formatted_parts);
    }

    $self->stash(
        %stash,
        summary_name => $summary_name,
        only_distri  => $only_distri,
    );
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

sub _add_dependency_to_graph {
    my ($edges, $cluster, $cluster_by_job, $parent_job_id, $child_job_id, $dependency_type) = @_;

    # add edge for chained dependencies
    if ($dependency_type eq OpenQA::Schema::Result::JobDependencies::CHAINED) {
        push(
            @$edges,
            {
                from => $parent_job_id,
                to   => $child_job_id,
            });
        return;
    }

    # add job to a cluster if dependency is parallel with
    return unless ($dependency_type eq OpenQA::Schema::Result::JobDependencies::PARALLEL);

    # check whether the jobs are already parted of a cluster
    my $job1_cluster_id = $cluster_by_job->{$child_job_id};
    my $job2_cluster_id = $cluster_by_job->{$parent_job_id};

    # merge existing cluster, extend existing cluster or create new cluster
    if ($job1_cluster_id && $job2_cluster_id) {
        # both jobs are already part of a cluster: merge clusters unless they're already the same
        push(@{$cluster->{$job1_cluster_id}}, @{delete $cluster_by_job->{$job2_cluster_id}})
          unless $job1_cluster_id == $job2_cluster_id;
    }
    elsif ($job1_cluster_id) {
        # only job1 is already in a cluster: move job2 into that cluster, too
        my $cluster = $cluster->{$job1_cluster_id};
        push(@$cluster, $parent_job_id);
        $cluster_by_job->{$parent_job_id} = $job1_cluster_id;
    }
    elsif ($job2_cluster_id) {
        # only job2 is already in a cluster: move job1 into that cluster, too
        my $cluster = $cluster->{$job2_cluster_id};
        push(@$cluster, $child_job_id);
        $cluster_by_job->{$child_job_id} = $job2_cluster_id;
    }
    else {
        # none of the jobs is already in a cluster: create a new one
        my $new_cluster_id = 'cluster_' . $child_job_id;
        $cluster->{$new_cluster_id}       = [$child_job_id, $parent_job_id];
        $cluster_by_job->{$child_job_id}  = $new_cluster_id;
        $cluster_by_job->{$parent_job_id} = $new_cluster_id;
    }
}

sub _add_dependency_to_node {
    my ($node, $parent, $dependency_type) = @_;

    my $key;
    if ($dependency_type eq OpenQA::Schema::Result::JobDependencies::CHAINED) {
        $key = 'start_after';
    }
    elsif ($dependency_type eq OpenQA::Schema::Result::JobDependencies::PARALLEL) {
        $key = 'parallel_with';
    }
    else {
        return;
    }

    push(@{$node->{$key}}, $parent->TEST);
}

sub _add_job {
    my ($visited, $nodes, $edges, $cluster, $cluster_by_job, $job) = @_;

    # add current job; return if already visited
    my $job_id = $job->id;
    return $job_id if $visited->{$job_id};
    $visited->{$job_id} = 1;

    # skip if the job has been cloned and the clone is also part of the dependency tree
    if (my $clone = $job->clone) {
        return _add_job($visited, $nodes, $edges, $cluster, $cluster_by_job, $clone);
    }

    my %node = (
        id            => $job_id,
        label         => $job->TEST,
        name          => $job->name,
        state         => $job->state,
        result        => $job->result,
        blocked_by_id => $job->blocked_by_id,
        start_after   => [],
        parallel_with => [],
    );
    push(@$nodes, \%node);

    # add parents
    for my $parent ($job->parents->all) {
        my ($parent_job, $dependency_type) = ($parent->parent, $parent->dependency);
        my $parent_job_id = _add_job($visited, $nodes, $edges, $cluster, $cluster_by_job, $parent_job) or next;
        _add_dependency_to_graph($edges, $cluster, $cluster_by_job, $parent_job_id, $job_id, $dependency_type);
        _add_dependency_to_node(\%node, $parent_job, $dependency_type);
    }

    # add children
    for my $child ($job->children->all) {
        _add_job($visited, $nodes, $edges, $cluster, $cluster_by_job, $child->child);
    }

    return $job_id;
}

sub dependencies {
    my ($self) = @_;

    # build dependency graph starting from the current job
    my $job = $self->get_current_job or return $self->reply->not_found;
    my (%visited, @nodes, @edges, %cluster, %cluster_by_job);
    _add_job(\%visited, \@nodes, \@edges, \%cluster, \%cluster_by_job, $job);

    $self->render(
        json => {
            nodes   => \@nodes,
            edges   => \@edges,
            cluster => \%cluster,
        });
}

1;
# vim: set sw=4 et:
