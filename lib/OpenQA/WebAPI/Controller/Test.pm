# Copyright (C) 2015-2021 SUSE LLC
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
# with this program; if not, see <http://www.gnu.org/licenses/>.

package OpenQA::WebAPI::Controller::Test;
use Mojo::Base 'Mojolicious::Controller', -signatures;

use OpenQA::Utils;
use OpenQA::Jobs::Constants;
use OpenQA::Schema::Result::Jobs;
use OpenQA::Schema::Result::JobDependencies;
use OpenQA::Utils qw(determine_web_ui_web_socket_url get_ws_status_only_url);
use Mojo::ByteStream;
use Mojo::Util 'xml_escape';
use Mojo::File 'path';
use File::Basename;
use POSIX 'strftime';
use Mojo::JSON qw(to_json decode_json);

sub referer_check {
    my ($self) = @_;
    return $self->reply->not_found if (!defined $self->param('testid'));
    my $referer = $self->req->headers->header('Referer') // '';
    if ($referer) {
        $self->schema->resultset('Jobs')->mark_job_linked($self->param('testid'), $referer);
    }
    return 1;
}

sub list {
    my ($self) = @_;
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

sub list_ajax ($self) {
    my $scope = ($self->param('relevant') ne 'false' ? 'relevant' : '');
    my @jobs  = $self->schema->resultset('Jobs')->complex_query(
        state    => [OpenQA::Jobs::Constants::FINAL_STATES],
        scope    => $scope,
        match    => $self->get_match_param,
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

    my $comment_data = $self->schema->resultset('Comments')->comment_data_for_jobs(\@jobs, {bugdetails => 1});
    my @list;
    for my $job (@jobs) {
        my $job_id        = $job->id;
        my $rendered_data = 0;
        if (my $cd = $comment_data->{$job_id}) {
            $rendered_data = $self->_render_comment_data_for_ajax($job_id, $cd);
        }
        push(
            @list,
            {
                DT_RowId     => 'job_' . $job_id,
                id           => $job_id,
                result_stats => $job->result_stats,
                deps         => $job->dependencies,
                clone        => $job->clone_id,
                test         => $job->TEST . '@' . ($job->MACHINE // ''),
                distri       => $job->DISTRI  // '',
                version      => $job->VERSION // '',
                flavor       => $job->FLAVOR  // '',
                arch         => $job->ARCH    // '',
                build        => $job->BUILD   // '',
                testtime     => ($job->t_finished // '') . 'Z',
                result       => $job->result,
                group        => $job->group_id,
                comment_data => $rendered_data,
                state        => $job->state,
            });
    }
    $self->render(json => {data => \@list});
}

sub _render_comment_data_for_ajax ($self, $job_id, $comment_data) {
    my %data;
    $data{comments}     = $comment_data->{comments};
    $data{reviewed}     = $comment_data->{reviewed};
    $data{label}        = $comment_data->{label};
    $data{comment_icon} = $self->comment_icon($job_id, $data{comments});
    my $bugs = $comment_data->{bugs};
    $data{bugs} = [
        map {
            my $bug = $comment_data->{bugdetails}->{$_};
            +{
                content   => $_,
                title     => $self->bugtitle_for($_, $bug),
                url       => $self->bugurl_for($_),
                css_class => $self->bugicon_for($_, $bug),
            };
        } sort keys %$bugs
    ];
    return \%data;
}

sub list_running_ajax {
    my ($self) = @_;

    my $running = $self->schema->resultset('Jobs')->complex_query(
        state    => [OpenQA::Jobs::Constants::EXECUTION_STATES],
        match    => $self->get_match_param,
        groupid  => $self->param('groupid'),
        order_by => [{-desc => 'me.t_started'}, {-desc => 'me.id'}],
        columns  => [
            qw(id MACHINE DISTRI VERSION FLAVOR ARCH BUILD TEST
              state result clone_id group_id t_started blocked_by_id priority
              passed_module_count failed_module_count softfailed_module_count
              skipped_module_count externally_skipped_module_count
            )
        ],
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
                distri   => $job->DISTRI  // '',
                version  => $job->VERSION // '',
                flavor   => $job->FLAVOR  // '',
                arch     => $job->ARCH    // '',
                build    => $job->BUILD   // '',
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

    my $scheduled = $self->schema->resultset('Jobs')->complex_query(
        state    => [OpenQA::Jobs::Constants::PRE_EXECUTION_STATES],
        match    => $self->get_match_param,
        groupid  => $self->param('groupid'),
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
                distri        => $job->DISTRI  // '',
                version       => $job->VERSION // '',
                flavor        => $job->FLAVOR  // '',
                arch          => $job->ARCH    // '',
                build         => $job->BUILD   // '',
                testtime      => $job->t_created . 'Z',
                group         => $job->group_id,
                state         => $job->state,
                blocked_by_id => $job->blocked_by_id,
                prio          => $job->priority,
            });
    }
    $self->render(json => {data => \@scheduled});
}

sub _stash_job {
    my ($self, $args) = @_;

    return undef unless my $job_id = $self->param('testid');
    return undef unless my $job    = $self->schema->resultset('Jobs')->find({id => $job_id}, $args);
    $self->stash(job => $job);
    return $job;
}

sub _stash_job_and_module_list {
    my ($self, $args) = @_;

    return undef unless my $job = $self->_stash_job($args);
    my $test_modules = read_test_modules($job);
    $self->stash(modlist => ($test_modules ? $test_modules->{modules} : []));
    return $job;
}

sub details {
    my ($self) = @_;

    return $self->reply->not_found unless my $job = $self->_stash_job;

    if ($job->should_show_autoinst_log) {
        my $log = $self->render_to_string('test/autoinst_log_within_details');
        return $self->render(json => {snippets => {header => $log}});
    }

    my $modules = read_test_modules($job);
    my @ret;

    for my $module (@{$modules->{modules}}) {
        for my $step (@{$module->{details}}) {
            delete $step->{needles};
        }

        my $hash = {
            name           => $module->{name},
            category       => $module->{category},
            result         => $module->{result},
            execution_time => $module->{execution_time},
            details        => $module->{details},
            flags          => []};

        for my $flag (qw(important fatal milestone always_rollback)) {
            if ($module->{$flag}) {
                push(@{$hash->{flags}}, $flag);
            }
        }

        push @ret, $hash;
    }

    my %tplargs = (moduleid => '$MODULE$', stepid => '$STEP$');
    my $snips   = {
        header        => $self->render_to_string('test/details'),
        bug_actions   => $self->include_branding("external_reporting", %tplargs),
        src_url       => $self->url_for('src_step',       testid      => $job->id, moduleid => '$MODULE$', stepid => 1),
        module_url    => $self->url_for('step',           testid      => $job->id, %tplargs),
        md5thumb_url  => $self->url_for('thumb_image',    md5_dirname => '$DIRNAME$', md5_basename => '$BASENAME$'),
        thumbnail_url => $self->url_for('test_thumbnail', testid      => $job->id,    filename     => '$FILENAME$')};

    return $self->render(json => {snippets => $snips, modules => \@ret});
}

sub external {
    my ($self) = @_;

    $self->_stash_job_and_module_list or return $self->reply->not_found;
    $self->render('test/external');
}

sub live {
    my ($self) = @_;

    my $job          = $self->_stash_job or return $self->reply->not_found;
    my $current_user = $self->current_user;
    my $worker       = $job->worker;
    my $worker_vnc   = ($worker ? $worker->host . ':' . (5990 + $worker->instance) : undef);
    $self->stash(
        {
            ws_developer_url         => determine_web_ui_web_socket_url($job->id),
            ws_status_only_url       => get_ws_status_only_url($job->id),
            developer_session        => $job->developer_session,
            is_devel_mode_accessible => $current_user && $current_user->is_operator,
            current_user_id          => $current_user ? $current_user->id : 'undefined',
            worker_vnc               => $worker_vnc,
        });
    $self->render('test/live');
}

sub downloads {
    my ($self) = @_;

    my $job = $self->_stash_job({prefetch => [qw(settings jobs_assets)]}) or return $self->reply->not_found;
    $self->stash(
        $job->result_dir
        ? {resultfiles => $job->test_resultfile_list, ulogs => $job->test_uploadlog_list}
        : {resultfiles => [], ulogs => []});
    $self->render('test/downloads');
}

sub settings {
    my ($self) = @_;

    $self->_stash_job({prefetch => 'settings'}) or return $self->reply->not_found;
    $self->render('test/settings');
}

=over 4

=item show_filesrc()

Returns the context of a config file of the selected job.
So this works in the same way as the test module source.

=back

=cut

sub show_filesrc {
    my ($self)      = @_;
    my $job         = $self->_stash_job or return $self->reply->not_found;
    my $jobid       = $self->param('testid');
    my $dir         = $self->stash('dir');
    my $data_uri    = $self->stash('link_path');
    my $testcasedir = testcasedir($job->DISTRI, $job->VERSION);
    # Use the testcasedir to determine the correct path
    my $filepath;
    if (-d path($testcasedir)->child($dir)) {
        $filepath = path($dir, $data_uri);
    }
    else {
        my $default_data_dir = $self->app->config->{job_settings_ui}->{default_data_dir};
        $filepath = path($default_data_dir, $dir, $data_uri);
    }

    if (my $casedir = $job->settings->single({key => 'CASEDIR'})) {
        my $casedir_url = Mojo::URL->new($casedir->value);
        # if CASEDIR points to a remote location let's assume it is a git repo
        # that we can reference like gitlab/github
        last unless $casedir_url->scheme;
        my $refspec = $casedir_url->fragment;
        # try to read vars.json from resultdir and replace branch by actual git hash if possible
        eval {
            my $vars_json = Mojo::File->new($job->result_dir(), 'vars.json')->slurp;
            my $vars      = decode_json($vars_json);
            $refspec = $vars->{TEST_GIT_HASH} if $vars->{TEST_GIT_HASH};
        };
        my $src_path = path('/blob', $refspec, $filepath);
        # github treats '.git' as optional extension which needs to be stripped
        $casedir_url->path($casedir_url->path =~ s/\.git//r . $src_path);
        $casedir_url->fragment('');
        return $self->redirect_to($casedir_url);
    }
    my $setting_file_path = path($testcasedir, $filepath);
    return $self->reply->not_found unless $setting_file_path && -e $setting_file_path;
    my $context = path($setting_file_path)->slurp;
    $self->render(
        'test/link_context',
        jid         => $jobid,
        title       => $setting_file_path,
        context     => "$context",
        contextpath => $setting_file_path
    );
}

sub comments {
    my ($self) = @_;

    $self->_stash_job({prefetch => 'comments'}) or return $self->reply->not_found;
    $self->render('test/comments');
}

sub infopanel {
    my ($self) = @_;

    my $job = $self->_stash_job or return $self->reply->not_found;
    $self->stash(
        {
            clone_of        => $self->schema->resultset('Jobs')->find({clone_id => $job->id}),
            worker          => $job->assigned_worker,
            additional_data => 1,
        });
    $self->render('test/infopanel');
}

sub get_current_job {
    my ($self) = @_;

    return $self->reply->not_found if (!defined $self->param('testid'));

    my $job = $self->schema->resultset("Jobs")->search(
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
            job                => $job,
            testname           => $job->name,
            distri             => $job->DISTRI,
            version            => $job->VERSION,
            build              => $job->BUILD,
            scenario           => $job->scenario_name,
            worker             => $job->worker,
            assigned_worker    => $job->assigned_worker,
            clone_of           => $self->schema->resultset('Jobs')->find({clone_id => $job->id}),
            show_dependencies  => !defined($job->clone_id) && $job->has_dependencies,
            show_autoinst_log  => $job->should_show_autoinst_log,
            show_investigation => $job->should_show_investigation,
            show_live_tab      => $job->state ne DONE,
        });
    $self->render('test/result');
}

sub job_next_previous_ajax ($self) {
    my $main_job   = $self->get_current_job;
    my $main_jobid = $main_job->id;
    my $p_limit    = $self->param('previous_limit') // 400;
    my $n_limit    = $self->param('next_limit')     // 100;

    my $schema  = $self->schema;
    my $jobs_rs = $schema->resultset('Jobs')->next_previous_jobs_query(
        $main_job, $main_jobid,
        previous_limit => $p_limit,
        next_limit     => $n_limit,
    );
    my @jobs         = $jobs_rs->all;
    my $comment_data = $self->schema->resultset('Comments')->comment_data_for_jobs(\@jobs, {bugdetails => 1});
    my $latest       = 1;
    my @data;
    for my $job (@jobs) {
        my $job_id = $job->id;
        $latest = $job_id > $latest ? $job_id : $latest;
        my $rendered_data = 0;
        if (my $cd = $comment_data->{$job_id}) {
            $rendered_data = $self->_render_comment_data_for_ajax($job_id, $cd);
        }
        push(
            @data,
            {
                DT_RowId      => 'job_result_' . $job_id,
                id            => $job_id,
                name          => $job->name,
                distri        => $job->DISTRI,
                version       => $job->VERSION,
                build         => $job->BUILD,
                deps          => $job->dependencies,
                result        => $job->result,
                result_stats  => $job->result_stats,
                state         => $job->state,
                clone         => $job->clone_id,
                failedmodules => $job->failed_modules(),
                iscurrent     => $job_id == $main_jobid ? 1                                  : undef,
                islatest      => $job_id == $latest     ? 1                                  : undef,
                finished      => $job->t_finished       ? $job->t_finished->datetime() . 'Z' : undef,
                duration      => $job->t_started
                  && $job->t_finished ? $self->format_time_duration($job->t_finished - $job->t_started) : 0,
                comment_data => $rendered_data,
            });
    }
    $self->render(json => {data => \@data});
}

sub _calculate_preferred_machines {
    my ($jobs) = @_;

    my %machines;
    for my $job (@$jobs) {
        next unless my $machine = $job->MACHINE;
        ($machines{$job->ARCH} ||= {})->{$machine}++;
    }
    my %preferred_machines;
    for my $arch (keys %machines) {
        my $max      = 0;
        my $machines = $machines{$arch};
        for my $machine (sort keys %$machines) {
            my $machine_count = $machines->{$machine};
            if ($machine_count > $max) {
                $max = $machine_count;
                $preferred_machines{$arch} = $machine;
            }
        }
    }
    return \%preferred_machines;
}

# Take an job objects arrayref and prepare data structures for 'overview'
sub prepare_job_results {
    my ($self, $jobs) = @_;
    my %archs;
    my %results;
    my $aggregated = {
        none         => 0,
        passed       => 0,
        failed       => 0,
        not_complete => 0,
        aborted      => 0,
        scheduled    => 0,
        running      => 0,
        unknown      => 0
    };
    my $preferred_machines = _calculate_preferred_machines($jobs);

    # read parameter for additional filtering
    my $failed_modules = $self->param_hash('failed_modules');
    my $states         = $self->param_hash('state');
    my $results        = $self->param_hash('result');
    my $archs          = $self->param_hash('arch');
    my $machines       = $self->param_hash('machine');

    # prefetch the number of available labels for those jobs
    my $schema       = $self->schema;
    my $comment_data = $schema->resultset('Comments')->comment_data_for_jobs($jobs, {bugdetails => 1});

    # prefetch test suite names from job settings
    my $job_settings
      = $schema->resultset('JobSettings')
      ->search({job_id => {-in => [map { $_->id } @$jobs]}, key => {-in => [qw(JOB_DESCRIPTION TEST_SUITE_NAME)]}});
    my %settings_by_job_id;
    for my $js ($job_settings->all) {
        $settings_by_job_id{$js->job_id}->{$js->key} = $js->value;
    }

    my %test_suite_names = map { $_->id => ($settings_by_job_id{$_->id}->{TEST_SUITE_NAME} // $_->TEST) } @$jobs;

    # prefetch descriptions from test suites
    my %desc_args = (in => [values %test_suite_names]);
    my @descriptions
      = $schema->resultset('TestSuites')->search({name => \%desc_args}, {columns => [qw(name description)]});
    my %descriptions = map { $_->name => $_->description } @descriptions;

    my @wanted_jobs = grep {
              (not $states         or $states->{$_->state})
          and (not $results        or $results->{$_->result})
          and (not $archs          or $archs->{$_->ARCH})
          and (not $machines       or $machines->{$_->MACHINE})
          and (not $failed_modules or $_->result eq OpenQA::Jobs::Constants::FAILED)
    } @$jobs;
    my @jobids                = map { $_->id } @wanted_jobs;
    my $failed_modules_by_job = $schema->resultset('JobModules')->search(
        {job_id => {-in => [@jobids]}, result   => 'failed'},
        {select => [qw(name job_id)],  order_by => 't_updated'},
    );
    my %failed_modules_by_job;
    push @{$failed_modules_by_job{$_->job_id}}, $_->name for $failed_modules_by_job->all;
    my %children_by_job;
    my %parents_by_job;
    my $s = $schema->resultset('JobDependencies')->search(
        {
            -or => [
                parent_job_id => {-in => \@jobids},
                child_job_id  => {-in => \@jobids},
            ],
        });
    while (my $dep = $s->next) {
        push @{$children_by_job{$dep->parent_job_id}}, $dep;
        push @{$parents_by_job{$dep->child_job_id}},   $dep;
    }
    foreach my $job (@wanted_jobs) {
        my $id     = $job->id;
        my $result = $job->overview_result(
            $comment_data, $aggregated, $failed_modules,
            $failed_modules_by_job{$id} || [],
            $self->param('todo')) or next;
        my $test   = $job->TEST;
        my $flavor = $job->FLAVOR || 'sweet';
        my $arch   = $job->ARCH   || 'noarch';
        $result->{deps} = to_json($job->dependencies($children_by_job{$id} || [], $parents_by_job{$id} || []));

        # Append machine name to TEST if it does not match the most frequently used MACHINE
        # for the jobs architecture
        if (   $job->MACHINE
            && $preferred_machines->{$job->ARCH}
            && $preferred_machines->{$job->ARCH} ne $job->MACHINE)
        {
            $test .= "@" . $job->MACHINE;
        }

        # Populate %archs
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
        my $description = $settings_by_job_id{$id}->{JOB_DESCRIPTION} // $descriptions{$test_suite_names{$id}};
        $results{$distri}{$version}{$flavor}{$test}{description} //= $description;
    }
    return (\%archs, \%results, $aggregated);
}

# appends the specified $distri and $version to $array_to_add_parts_to as string or if $raw as Mojo::ByteStream
sub _add_distri_and_version_to_summary {
    my ($array_to_add_parts_to, $distri, $version, $raw) = @_;

    for my $part ($distri, $version) {
        # handle case when multiple distri/version parameters have been specified
        $part = $part->{-in} if (ref $part eq 'HASH');
        next unless $part;

        # separate distri and version with a whitespace
        push(@$array_to_add_parts_to, ' ') if (@$array_to_add_parts_to);

        if (ref $part eq 'ARRAY') {
            # separate multiple distris/versions using a slash
            if (@$part) {
                push(@$array_to_add_parts_to, map { ($raw ? Mojo::ByteStream->new($_) : $_, '/') } @$part);
                pop(@$array_to_add_parts_to);
            }
        }
        elsif (ref $part ne 'HASH') {
            push(@$array_to_add_parts_to, $raw ? Mojo::ByteStream->new($part) : $part);
        }
    }
}

# A generic query page showing test results in a configurable matrix
sub overview {
    my ($self) = @_;
    my ($search_args, $groups) = $self->compose_job_overview_search_args;
    my $validation = $self->validation;
    $validation->optional('t')->datetime;
    my $until = $validation->param('t');
    my %stash = (
        # build, version, distri are not mandatory and therefore not
        # necessarily come from the search args so they can be undefined.
        build   => ref $search_args->{build} eq 'ARRAY' ? join(',', @{$search_args->{build}}) : $search_args->{build},
        version => $search_args->{version},
        distri  => $search_args->{distri},
        groups  => $groups,
        until   => $until,
    );
    my @latest_jobs = $self->schema->resultset('Jobs')->complex_query(%$search_args)->latest_jobs($until);
    ($stash{archs}, $stash{results}, $stash{aggregated}) = $self->prepare_job_results(\@latest_jobs);

    # determine distri/version from job results if not explicitly specified via search args
    my @distris = keys %{$stash{results}};
    my $formatted_distri;
    my $formatted_version;
    my $only_distri = scalar @distris == 1;
    if (!defined $stash{distri} && $only_distri) {
        $formatted_distri = $distris[0];
        if (!defined $stash{version}) {
            my @versions = keys %{$stash{results}->{$formatted_distri}};
            $formatted_version = $versions[0] if (scalar @versions == 1);
        }
    }

    # compose summary for "Overall Summary of ..."
    my @summary_parts;
    if (@$groups) {
        # use groups if present
        push(@summary_parts,
            map { ($self->link_to($_->name => $self->url_for('group_overview', groupid => $_->id)), ', ') } @$groups);
        pop(@summary_parts);
    }
    else {
        # add pre-formatted distri and version as Mojo::ByteStream
        _add_distri_and_version_to_summary(\@summary_parts, $formatted_distri, $formatted_version, 1);

        # add distri and version from query parameters as regular strings
        _add_distri_and_version_to_summary(\@summary_parts, $stash{distri}, $stash{version}, 0);
    }

    $self->stash(
        %stash,
        summary_parts => \@summary_parts,
        only_distri   => $only_distri,
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
    my $job = $self->schema->resultset("Jobs")->complex_query(%search_args)->first;
    return $self->render(text => 'No matching job found', status => 404) unless $job;
    $self->stash(testid => $job->id);
    return $self->_show($job);
}

sub export {
    my ($self) = @_;
    $self->res->headers->content_type('text/plain');

    my @groups = $self->schema->resultset("JobGroups")->search(undef, {order_by => 'name'});

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
    for my $detail (@{$module->results->{details}}) {
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
    if (   $dependency_type eq OpenQA::JobDependencies::Constants::CHAINED
        || $dependency_type eq OpenQA::JobDependencies::Constants::DIRECTLY_CHAINED)
    {
        push(
            @$edges,
            {
                from => $parent_job_id,
                to   => $child_job_id,
            });
        return undef;
    }

    # add job to a cluster if dependency is parallel with
    return undef unless ($dependency_type eq OpenQA::JobDependencies::Constants::PARALLEL);

    # check whether the jobs are already parted of a cluster
    my $job1_cluster_id = $cluster_by_job->{$child_job_id};
    my $job2_cluster_id = $cluster_by_job->{$parent_job_id};

    # merge existing cluster, extend existing cluster or create new cluster
    if ($job1_cluster_id && $job2_cluster_id) {
        # both jobs are already part of a cluster: merge clusters unless they're already the same
        push(@{$cluster->{$job1_cluster_id}}, @{delete $cluster_by_job->{$job2_cluster_id}})
          unless $job1_cluster_id eq $job2_cluster_id;
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

    if (my $key = OpenQA::JobDependencies::Constants::name($dependency_type)) {
        push(@{$node->{$key}}, $parent->TEST);
    }
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
        label         => $job->label,
        name          => $job->name,
        state         => $job->state,
        result        => $job->result,
        blocked_by_id => $job->blocked_by_id,
    );
    $node{$_} = [] for OpenQA::JobDependencies::Constants::names;
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

sub investigate {
    my ($self) = @_;
    return $self->reply->not_found unless my $job = $self->get_current_job;
    my $investigation = $job->investigate;
    $self->render(json => $investigation);
}

1;
