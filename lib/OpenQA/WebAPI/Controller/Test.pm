# Copyright 2015-2021 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::WebAPI::Controller::Test;
use Mojo::Base 'Mojolicious::Controller', -signatures;

use OpenQA::App;
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
use List::Util qw(min);

use constant DEPENDENCY_DEBUG_INFO => $ENV{OPENQA_DEPENDENCY_DEBUG_INFO};

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
    my $scope = $self->param('relevant');
    $scope = $scope && $scope ne 'false' && $scope ne '0' ? 'relevant' : '';
    my $limits = OpenQA::App->singleton->config->{misc_limits};
    my @jobs = $self->schema->resultset('Jobs')->complex_query(
        state => [OpenQA::Jobs::Constants::FINAL_STATES],
        scope => $scope,
        match => $self->get_match_param,
        groupid => $self->param('groupid'),
        limit => min(
            $limits->{all_tests_max_finished_jobs},
            $self->param('limit') // $limits->{all_tests_default_finished_jobs}
        ),
        order_by => \'COALESCE(me.t_finished, me.t_updated) DESC, me.id DESC',
        columns => [
            qw(id MACHINE DISTRI VERSION FLAVOR ARCH BUILD TEST
              state clone_id result group_id t_finished t_updated
              passed_module_count softfailed_module_count
              failed_module_count skipped_module_count
              externally_skipped_module_count
            )
        ],
        prefetch => [qw(children parents)],
    )->all;

    my $comment_data = $self->schema->resultset('Comments')->comment_data_for_jobs(\@jobs, {bugdetails => 1});
    my @list;
    my $todo = $self->param('todo');
    for my $job (@jobs) {
        next if $todo && !$job->overview_result($comment_data, {}, undef, [], $todo);

        my $job_id = $job->id;
        my $rendered_data = 0;
        if (my $cd = $comment_data->{$job_id}) {
            $rendered_data = $self->_render_comment_data_for_ajax($job_id, $cd);
        }
        push(
            @list,
            {
                DT_RowId => 'job_' . $job_id,
                id => $job_id,
                result_stats => $job->result_stats,
                deps => $job->dependencies,
                clone => $job->clone_id,
                test => $job->TEST . '@' . ($job->MACHINE // ''),
                distri => $job->DISTRI // '',
                version => $job->VERSION // '',
                flavor => $job->FLAVOR // '',
                arch => $job->ARCH // '',
                build => $job->BUILD // '',
                testtime => ($job->t_finished // $job->t_updated // '') . 'Z',
                result => $job->result,
                group => $job->group_id,
                comment_data => $rendered_data,
                state => $job->state,
            });
    }
    $self->render(json => {data => \@list});
}

sub _render_comment_data_for_ajax ($self, $job_id, $comment_data) {
    my %data;
    $data{comments} = $comment_data->{comments};
    $data{reviewed} = $comment_data->{reviewed};
    $data{label} = $comment_data->{label};
    $data{comment_icon} = $self->comment_icon($job_id, $data{comments});
    my $bugs = $comment_data->{bugs};
    $data{bugs} = [
        map {
            my $bug = $comment_data->{bugdetails}->{$_};
            +{
                content => $_,
                title => $self->bugtitle_for($_, $bug),
                url => $self->bugurl_for($_),
                css_class => $self->bugicon_for($_, $bug),
            };
        } sort keys %$bugs
    ];
    return \%data;
}

sub list_running_ajax {
    my ($self) = @_;

    my $running = $self->schema->resultset('Jobs')->complex_query(
        state => [OpenQA::Jobs::Constants::EXECUTION_STATES],
        match => $self->get_match_param,
        groupid => $self->param('groupid'),
        order_by => [{-desc => 'me.t_started'}, {-desc => 'me.id'}],
        columns => [
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
                id => $job_id,
                clone => $job->clone_id,
                test => $job->TEST . '@' . ($job->MACHINE // ''),
                distri => $job->DISTRI // '',
                version => $job->VERSION // '',
                flavor => $job->FLAVOR // '',
                arch => $job->ARCH // '',
                build => $job->BUILD // '',
                testtime => ($job->t_started // '') . 'Z',
                group => $job->group_id,
                state => $job->state,
                progress => $job->progress_info,
            });
    }
    $self->render(json => {data => \@running});
}

sub list_scheduled_ajax {
    my ($self) = @_;

    my $scheduled = $self->schema->resultset('Jobs')->complex_query(
        state => [OpenQA::Jobs::Constants::PRE_EXECUTION_STATES],
        match => $self->get_match_param,
        groupid => $self->param('groupid'),
        order_by => [{-desc => 'me.t_created'}, {-desc => 'me.id'}],
        columns => [
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
                DT_RowId => 'job_' . $job_id,
                id => $job_id,
                clone => $job->clone_id,
                test => $job->TEST . '@' . ($job->MACHINE // ''),
                distri => $job->DISTRI // '',
                version => $job->VERSION // '',
                flavor => $job->FLAVOR // '',
                arch => $job->ARCH // '',
                build => $job->BUILD // '',
                testtime => $job->t_created . 'Z',
                group => $job->group_id,
                state => $job->state,
                blocked_by_id => $job->blocked_by_id,
                prio => $job->priority,
            });
    }
    $self->render(json => {data => \@scheduled});
}

sub _stash_job {
    my ($self, $args) = @_;

    return undef unless my $job_id = $self->param('testid');
    return undef unless my $job = $self->schema->resultset('Jobs')->find({id => $job_id}, $args);
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
            name => $module->{name},
            category => $module->{category},
            result => $module->{result},
            execution_time => $module->{execution_time},
            details => $module->{details},
            flags => []};

        for my $flag (qw(important fatal milestone always_rollback)) {
            if ($module->{$flag}) {
                push(@{$hash->{flags}}, $flag);
            }
        }

        push @ret, $hash;
    }

    my %tplargs = (moduleid => '$MODULE$', stepid => '$STEP$');
    my $snips = {
        header => $self->render_to_string('test/details'),
        bug_actions => $self->include_branding("external_reporting", %tplargs),
        src_url => $self->url_for('src_step', testid => $job->id, moduleid => '$MODULE$', stepid => 1),
        module_url => $self->url_for('step', testid => $job->id, %tplargs),
        md5thumb_url => $self->url_for('thumb_image', md5_dirname => '$DIRNAME$', md5_basename => '$BASENAME$'),
        thumbnail_url => $self->url_for('test_thumbnail', testid => $job->id, filename => '$FILENAME$')};

    return $self->render(json => {snippets => $snips, modules => \@ret});
}

sub external {
    my ($self) = @_;

    $self->_stash_job_and_module_list or return $self->reply->not_found;
    $self->render('test/external');
}

sub live {
    my ($self) = @_;

    my $job = $self->_stash_job or return $self->reply->not_found;
    my $current_user = $self->current_user;
    my $worker = $job->worker;
    my $worker_vnc = ($worker ? $worker->host . ':' . (5990 + $worker->instance) : undef);
    $self->stash(
        {
            ws_developer_url => determine_web_ui_web_socket_url($job->id),
            ws_status_only_url => get_ws_status_only_url($job->id),
            developer_session => $job->developer_session,
            is_devel_mode_accessible => $current_user && $current_user->is_operator,
            current_user_id => $current_user ? $current_user->id : 'undefined',
            worker_vnc => $worker_vnc,
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
    my ($self) = @_;
    my $job = $self->_stash_job or return $self->reply->not_found;
    my $jobid = $self->param('testid');
    my $dir = $self->stash('dir');
    my $data_uri = $self->stash('link_path');
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
            my $vars = decode_json($vars_json);
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
        jid => $jobid,
        title => $setting_file_path,
        context => "$context",
        contextpath => $setting_file_path
    );
}

sub comments {
    my ($self) = @_;

    $self->_stash_job({prefetch => 'comments', order_by => 'comments.id'}) or return $self->reply->not_found;
    $self->render('test/comments');
}

my $ANCESTORS_LIMIT = 10;
sub _stash_clone_info ($self, $job) {
    $self->stash(
        {
            ancestors => $job->ancestors($ANCESTORS_LIMIT),
            ancestors_limit => $ANCESTORS_LIMIT,
            clone_of => $self->schema->resultset('Jobs')->find({clone_id => $job->id}),
        });
}

sub infopanel {
    my ($self) = @_;
    my $job = $self->_stash_job or return $self->reply->not_found;
    $self->stash({worker => $job->assigned_worker, additional_data => 1});
    $self->_stash_clone_info($job);
    $self->render('test/infopanel');
}

sub _get_current_job ($self, $with_assets = 0) {
    return $self->reply->not_found unless defined $self->param('testid');

    my $job = $self->schema->resultset("Jobs")
      ->find($self->param('testid'), {$with_assets ? (prefetch => qw(jobs_assets)) : ()});
    return $job;
}

sub show ($self) { $self->_show($self->_get_current_job(1)) }

sub _show {
    my ($self, $job) = @_;
    return $self->reply->not_found unless $job;

    $self->stash(
        {
            job => $job,
            testname => $job->name,
            distri => $job->DISTRI,
            version => $job->VERSION,
            build => $job->BUILD,
            scenario => $job->scenario_name,
            worker => $job->worker,
            assigned_worker => $job->assigned_worker,
            show_dependencies => $job->has_dependencies,
            show_autoinst_log => $job->should_show_autoinst_log,
            show_investigation => $job->should_show_investigation,
            show_live_tab => $job->state ne DONE,
        });
    $self->_stash_clone_info($job);
    $self->render('test/result');
}

sub job_next_previous_ajax ($self) {
    return $self->reply->not_found unless my $main_job = $self->_get_current_job;
    my $main_jobid = $main_job->id;
    my $p_limit = $self->param('previous_limit') // 400;
    my $n_limit = $self->param('next_limit') // 100;

    my $schema = $self->schema;
    my $jobs_rs = $schema->resultset('Jobs')->next_previous_jobs_query(
        $main_job, $main_jobid,
        previous_limit => $p_limit,
        next_limit => $n_limit,
    );
    my @jobs = $jobs_rs->all;
    my $comment_data = $self->schema->resultset('Comments')->comment_data_for_jobs(\@jobs, {bugdetails => 1});
    my $latest = 1;
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
                DT_RowId => 'job_result_' . $job_id,
                id => $job_id,
                name => $job->name,
                distri => $job->DISTRI,
                version => $job->VERSION,
                build => $job->BUILD,
                deps => $job->dependencies,
                result => $job->result,
                result_stats => $job->result_stats,
                state => $job->state,
                clone => $job->clone_id,
                failedmodules => $job->failed_modules(),
                iscurrent => $job_id == $main_jobid ? 1 : undef,
                islatest => $job_id == $latest ? 1 : undef,
                finished => $job->t_finished ? $job->t_finished->datetime() . 'Z' : undef,
                duration => $job->t_started
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
        my $max = 0;
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
sub _prepare_job_results ($self, $all_jobs, $limit) {
    my %archs;
    my %results;
    my $aggregated = {
        none => 0,
        passed => 0,
        failed => 0,
        not_complete => 0,
        aborted => 0,
        scheduled => 0,
        running => 0,
        unknown => 0
    };
    my $preferred_machines = _calculate_preferred_machines($all_jobs);

    # read parameter for additional filtering
    my $failed_modules = $self->param_hash('failed_modules');
    my $states = $self->param_hash('state');
    my $results = $self->param_hash('result');
    my $archs = $self->param_hash('arch');
    my $machines = $self->param_hash('machine');

    my @jobs = grep {
              (not $states or $states->{$_->state})
          and (not $results or $results->{$_->result})
          and (not $archs or $archs->{$_->ARCH})
          and (not $machines or $machines->{$_->MACHINE})
          and (not $failed_modules or $_->result eq OpenQA::Jobs::Constants::FAILED)
    } @$all_jobs;
    my $limit_exceeded = @jobs >= $limit;
    @jobs = @jobs[0 .. ($limit - 1)] if $limit_exceeded;
    my @jobids = map { $_->id } @jobs;

    # prefetch the number of available labels for those jobs
    my $schema = $self->schema;
    my $comment_data = $schema->resultset('Comments')->comment_data_for_jobs(\@jobs, {bugdetails => 1});

    # prefetch test suite names from job settings
    my $job_settings
      = $schema->resultset('JobSettings')
      ->search({job_id => {-in => [map { $_->id } @jobs]}, key => {-in => [qw(JOB_DESCRIPTION TEST_SUITE_NAME)]}});
    my %settings_by_job_id;
    for my $js ($job_settings->all) {
        $settings_by_job_id{$js->job_id}->{$js->key} = $js->value;
    }

    my %test_suite_names = map { $_->id => ($settings_by_job_id{$_->id}->{TEST_SUITE_NAME} // $_->TEST) } @jobs;

    # prefetch descriptions from test suites
    my %desc_args = (in => [values %test_suite_names]);
    my @descriptions
      = $schema->resultset('TestSuites')->search({name => \%desc_args}, {columns => [qw(name description)]});
    my %descriptions = map { $_->name => $_->description } @descriptions;

    my $failed_modules_by_job = $schema->resultset('JobModules')->search(
        {job_id => {-in => [@jobids]}, result => 'failed'},
        {select => [qw(name job_id)], order_by => 't_updated'},
    );
    my %failed_modules_by_job;
    push @{$failed_modules_by_job{$_->job_id}}, $_->name for $failed_modules_by_job->all;
    my %children_by_job;
    my %parents_by_job;
    my $s = $schema->resultset('JobDependencies')->search(
        {
            -or => [
                parent_job_id => {-in => \@jobids},
                child_job_id => {-in => \@jobids},
            ],
        });
    while (my $dep = $s->next) {
        push @{$children_by_job{$dep->parent_job_id}}, $dep;
        push @{$parents_by_job{$dep->child_job_id}}, $dep;
    }
    foreach my $job (@jobs) {
        my $id = $job->id;
        my $result = $job->overview_result(
            $comment_data, $aggregated, $failed_modules,
            $failed_modules_by_job{$id} || [],
            $self->param('todo')) or next;
        my $test = $job->TEST;
        my $flavor = $job->FLAVOR || 'sweet';
        my $arch = $job->ARCH || 'noarch';
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
        my $distri = $job->DISTRI;
        my $version = $job->VERSION;
        $archs{$distri}{$version}{$flavor} //= [];
        push(@{$archs{$distri}{$version}{$flavor}}, $arch)
          unless (grep { $arch eq $_ } @{$archs{$distri}{$version}{$flavor}});

        # Populate %results by putting all distri, version, build, flavor into
        # levels of the hashes and just iterate over all levels in template.
        # if there is only one member on each level, do not output the key of
        # that level to resemble previous behaviour or maybe better, show it
        # in aggregation only
        $results{$distri} //= {};
        $results{$distri}{$version} //= {};
        $results{$distri}{$version}{$flavor} //= {};
        $results{$distri}{$version}{$flavor}{$test} //= {};
        $results{$distri}{$version}{$flavor}{$test}{$arch} = $result;

        # add description
        my $description = $settings_by_job_id{$id}->{JOB_DESCRIPTION} // $descriptions{$test_suite_names{$id}};
        $results{$distri}{$version}{$flavor}{$test}{description} //= $description;
    }
    return ($limit_exceeded, \%archs, \%results, $aggregated);
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
    my $config = OpenQA::App->singleton->config;
    my $validation = $self->validation;
    $validation->optional('t')->datetime;
    my $until = $validation->param('t');
    my %stash = (
        # build, version, distri are not mandatory and therefore not
        # necessarily come from the search args so they can be undefined.
        build => ref $search_args->{build} eq 'ARRAY' ? join(',', @{$search_args->{build}}) : $search_args->{build},
        version => $search_args->{version},
        distri => $search_args->{distri},
        groups => $groups,
        until => $until,
        parallel_children_collapsable_results_sel => $config->{global}->{parallel_children_collapsable_results_sel},
    );
    my @jobs = $self->schema->resultset('Jobs')->complex_query(%$search_args)->latest_jobs($until);

    my $limit = $config->{misc_limits}->{tests_overview_max_jobs};
    (my $limit_exceeded, $stash{archs}, $stash{results}, $stash{aggregated})
      = $self->_prepare_job_results(\@jobs, $limit);

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
        only_distri => $only_distri,
        limit_exceeded => $limit_exceeded ? $limit : undef
    );
    $self->respond_to(
        json => {json => \%stash},
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

sub module_fails {
    my ($self) = @_;

    unless (defined $self->param('testid') and defined $self->param('moduleid')) {
        return $self->reply->not_found;
    }

    my $module = $self->app->schema->resultset("JobModules")->search(
        {
            job_id => $self->param('testid'),
            name => $self->param('moduleid'),
        })->first;

    my @needles;

    my $counter = 0;
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
            failed_needles => \@needles
        });
}

sub _add_dependency_to_graph ($dependency_data, $parent_job_id, $child_job_id, $dependency_type) {

    # add edge for chained dependencies
    if (   $dependency_type eq OpenQA::JobDependencies::Constants::CHAINED
        || $dependency_type eq OpenQA::JobDependencies::Constants::DIRECTLY_CHAINED)
    {
        push(@{$dependency_data->{edges}}, {from => $parent_job_id, to => $child_job_id});
        return undef;
    }

    # add job to a cluster if dependency is parallel with
    return undef unless ($dependency_type eq OpenQA::JobDependencies::Constants::PARALLEL);

    # check whether the jobs are already parted of a cluster
    my $cluster_by_job = $dependency_data->{cluster_by_job};
    my $job1_cluster_id = $cluster_by_job->{$child_job_id};
    my $job2_cluster_id = $cluster_by_job->{$parent_job_id};

    # merge existing cluster, extend existing cluster or create new cluster
    my $cluster = $dependency_data->{cluster};
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
        $cluster->{$new_cluster_id} = [$child_job_id, $parent_job_id];
        $cluster_by_job->{$child_job_id} = $new_cluster_id;
        $cluster_by_job->{$parent_job_id} = $new_cluster_id;
    }
}

sub _add_dependency_to_node ($node, $parent, $dependency_type) {
    if (my $key = OpenQA::JobDependencies::Constants::name($dependency_type)) {
        push(@{$node->{$key}}, $parent->TEST);
    }
}

sub _add_job ($dependency_data, $job, $as_child_of, $preferred_depth) {

    # add current job; return if already visited
    my $job_id = $job->id;
    my $visited = $dependency_data->{visited};
    return $job_id if $visited->{$job_id};
    $visited->{$job_id} = 1;

    # show only the latest child jobs but still require the cloned job to be an actual child
    if ($as_child_of) {
        my $clone = $job->clone;
        if ($clone && $clone->is_child_of($as_child_of)) {
            return _add_job($dependency_data, $clone, $as_child_of, $preferred_depth);
        }
    }

    my $name = $job->name;
    my ($descendants, $ancestors);
    if (DEPENDENCY_DEBUG_INFO) {
        ($descendants, $ancestors) = ($job->descendants, $job->ancestors);
        $name .= " (ancestors: $ancestors, descendants: $descendants, ";
        $name .= "as child: $as_child_of, preferred depth: $preferred_depth)";
    }
    my %node = (
        id => $job_id,
        label => $job->label,
        name => $name,
        state => $job->state,
        result => $job->result,
        blocked_by_id => $job->blocked_by_id,
    );
    $node{$_} = [] for OpenQA::JobDependencies::Constants::names;
    push(@{$dependency_data->{nodes}}, \%node);

    # add parents
    for my $parent ($job->parents->all) {
        my ($parent_job, $dependency_type) = ($parent->parent, $parent->dependency);
        my $parent_job_id = _add_job($dependency_data, $parent_job, $as_child_of, $preferred_depth) or next;
        _add_dependency_to_graph($dependency_data, $parent_job_id, $job_id, $dependency_type);
        _add_dependency_to_node(\%node, $parent_job, $dependency_type);
    }

    # add children
    for my $child ($job->children->all) {
        # add chained deps only if we're still on the preferred depth to avoid dragging too many jobs into the tree
        next
          if ($ancestors //= $job->ancestors) > $preferred_depth
          && $child->dependency != OpenQA::JobDependencies::Constants::PARALLEL;
        _add_job($dependency_data, $child->child, $job_id, $preferred_depth);
    }

    return $job_id;
}

sub dependencies ($self) {

    # build dependency graph starting from the current job
    my $job = $self->_get_current_job or return $self->reply->not_found;
    my (@nodes, @edges, %cluster);
    my %data = (visited => {}, nodes => \@nodes, edges => \@edges, cluster => \%cluster, cluster_by_job => {});
    _add_job(\%data, $job, 0, $job->ancestors);
    $self->render(json => {nodes => \@nodes, edges => \@edges, cluster => \%cluster});
}

sub investigate {
    my ($self) = @_;
    return $self->reply->not_found unless my $job = $self->_get_current_job;
    my $git_limit = OpenQA::App->singleton->config->{global}->{job_investigate_git_log_limit} // 200;
    my $investigation = $job->investigate(git_limit => $git_limit);
    $self->render(json => $investigation);
}

1;
