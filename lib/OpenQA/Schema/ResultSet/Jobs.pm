# Copyright 2014-2021 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Schema::ResultSet::Jobs;

use Mojo::Base 'DBIx::Class::ResultSet', -signatures;
use DBIx::Class::Timestamps 'now';
use Date::Format 'time2str';
use Encode qw(decode_utf8);
use File::Basename 'basename';
use IPC::Run;
use OpenQA::Config;
use OpenQA::App;
use OpenQA::Jobs::Constants;
use OpenQA::Constants qw(DEFAULT_MAX_JOB_TIME);
use OpenQA::Jobs::Constants qw(PENDING_STATES EXECUTION_STATES);
use OpenQA::Log qw(log_trace log_debug log_info);
use OpenQA::Schema::Result::Jobs;
use OpenQA::Schema::Result::JobDependencies;
use OpenQA::Utils qw(testcasedir href_to_bugref);
use Mojo::File 'path';
use Mojo::JSON 'encode_json';
use Mojo::URL;
use Mojolicious::Validator;
use Mojolicious::Validator::Validation;
use Time::HiRes 'time';
use DateTime;
use List::Util qw(any uniq);
use Scalar::Util qw(looks_like_number);

=head2 latest_build

=over

=item Arguments: hash with settings values to filter by

=item Return value: value of BUILD for the latests job matching the arguments

=back

Returns the value of the BUILD setting of the latest (most recently created)
job that matches the settings provided as argument. Useful to find the
latest build for a given pair of distri and version.

=cut

sub latest_build ($self, %args) {
    my @conds;
    my %attrs;
    my $rsource = $self->result_source;
    my $schema = $rsource->schema;

    my $groupid = delete $args{groupid};
    push @conds, {'me.group_id' => $groupid} if defined $groupid;

    $attrs{join} = 'settings';
    $attrs{rows} = 1;
    $attrs{order_by} = {-desc => 'me.id'};    # More reliable for tests than t_created
    $attrs{columns} = qw(BUILD);

    my $job_settings = $schema->resultset('JobSettings');
    foreach my $key (keys %args) {
        my $key_uc = uc $key;
        my $value = $args{$key};
        if (any { $key_uc eq $_ } OpenQA::Schema::Result::Jobs::MAIN_SETTINGS) {
            push @conds, {'me.' . $key_uc => $value};
        }
        else {
            my $subquery = $job_settings->search({key => $key_uc, value => $value});
            push @conds, {'me.id' => {-in => $subquery->get_column('job_id')->as_query}};
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

sub latest_jobs ($self, $until = undef) {
    my @jobs = $self->search($until ? {'me.t_created' => {'<=' => $until}} : undef, {order_by => ['me.id DESC']});

    my @latest;
    my %seen;
    foreach my $job (@jobs) {
        my $key = join '-', map { $job->$_ // '' } OpenQA::Schema::Result::Jobs::MAIN_SETTINGS;
        push @latest, $job unless $seen{$key}++;
    }

    return @latest;
}

sub _apply_auto_worker_class_assignment ($settings_ref, $config = {}) {
    my $rules = OpenQA::Config::parse_worker_class_auto_assignment($config);
    return unless @$rules;

    my @existing = grep { $_ } split qr/,/, $settings_ref->{WORKER_CLASS} // '';
    my @to_add = grep {
        my $pattern = $_->{pattern};
        !any { $_ =~ $pattern } @existing;
    } @$rules;
    return unless @to_add;

    for my $rule (@to_add) {
        log_info("Auto-assigning worker class '$rule->{class}' to job (no match for pattern '$rule->{pattern}')");
    }
    $settings_ref->{WORKER_CLASS} = join ',', sort(uniq(@existing, map { $_->{class} } @to_add));
}

sub _build_job_settings ($settings_ref) {
    my $now = now;
    my @job_settings;
    for my $key (keys %$settings_ref) {
        my $val = $settings_ref->{$key};
        push @job_settings, map { {t_created => $now, t_updated => $now, key => $key, value => $_} }
          grep { defined $_ } $key =~ qr/(^WORKER_CLASS|\[\])$/ ? split(m/,/, $val // '') : ($val);
    }
    return \@job_settings;
}

sub create_from_settings ($self, $settings, $scheduled_product_id = undef) {
    my %settings = %$settings;
    my %new_job_args;

    my @invalid_keys = grep { $_ =~ /^(PUBLISH_HDD|FORCE_PUBLISH_HDD|STORE_HDD)\S+(\d+)$/ && $settings{$_} =~ /\// }
      keys %settings;
    die 'The ' . join(',', @invalid_keys) . " cannot include / in value\n" if @invalid_keys;

    # validate special settings
    my %special_settings = (TEST => delete $settings{TEST}, _PRIORITY => delete $settings{_PRIORITY});
    my $v
      = Mojolicious::Validator::Validation->new(validator => Mojolicious::Validator->new, input => \%special_settings);
    my $test = $v->required('TEST')->like(TEST_NAME_REGEX)->param;
    my $prio = $v->optional('_PRIORITY')->num->param;
    die 'The following settings are invalid: ' . join(', ', @{$v->failed}) . "\n" if $v->has_error;

    # assign group ID and priority
    my $group_id = delete $settings{GROUP_ID};
    $settings{_GROUP_ID} = $group_id if defined $group_id;
    my ($group_args, $group) = OpenQA::Schema::Result::Jobs::extract_group_args_from_settings(\%settings);
    $new_job_args{priority} = $prio if defined $prio;
    if ($group) {
        $new_job_args{group_id} = $group->id;
        $new_job_args{priority} //= $group->default_priority;
    }

    $self->_handle_dependency_settings(\%settings, \%new_job_args);

    for my $key (keys %settings) {
        my $value = $settings{$key};
        $settings{$key} = decode_utf8 encode_json $value if (ref $value eq 'ARRAY' || ref $value eq 'HASH');
    }

    # move important keys from the settings directly to the job
    $new_job_args{TEST} = $test;
    for my $key (OpenQA::Schema::Result::Jobs::MAIN_SETTINGS) {
        if (my $value = delete $settings{$key}) { $new_job_args{$key} = $value }
    }

    $settings{WORKER_CLASS} ||= 'qemu_' . ($new_job_args{ARCH} // 'x86_64');
    my $config = OpenQA::App->singleton && OpenQA::App->singleton->config;
    _apply_auto_worker_class_assignment(\%settings, $config);

    $new_job_args{scheduled_product_id} = $scheduled_product_id;

    my $debug_msg = $self->_apply_prio_throttling(\%settings, \%new_job_args, $group, $config);
    $settings{_PRIORITY_EXPLANATION} = $debug_msg if $debug_msg;

    my $job = $self->create(\%new_job_args);
    log_debug(sprintf "(Job %d) $debug_msg", $job->id) if $debug_msg;

    $job->settings->populate(_build_job_settings(\%settings));
    $job->register_assets_from_settings;

    log_info('Ignoring invalid group ' . encode_json($group_args) . ' when creating new job ' . $job->id)
      if keys %$group_args && !$group;
    $job->calculate_blocked_by;
    return $job;
}


sub _update_priority ($value, $throt_config, $job_args) {
    my $scale = $throt_config->{scale} // 0;
    my $reference = $throt_config->{reference} // 0;
    my $prio = int(($value - $reference) * $scale);
    $job_args->{priority} += $prio;
    my $sign = $prio >= 0 ? '+' : '';
    return " [$sign$prio: value $value, scale $scale" . ($reference ? ", reference $reference]" : ']');
}

sub _apply_max_job_time_prio ($factor, $time, $throt_config, $job_args) {
    my $info = '';
    $factor = (looks_like_number $factor && $factor > 0) ? $factor : 1;
    $time = (looks_like_number $time && $time > 0) ? $time : DEFAULT_MAX_JOB_TIME;
    $time = (int($time * $factor));
    if ($time > DEFAULT_MAX_JOB_TIME && defined $throt_config) {
        $info = 'MAX_JOB_TIME' . _update_priority($time, $throt_config, $job_args);
    }
    return $info;
}

sub _apply_prio_throttling ($self, $settings, $new_job_args, $group = undef, $config = undef) {
    my $debug_msg;
    my $base_prio = $new_job_args->{priority} // 0;
    my @throttling_info;
    if ($config && (my $throttling = $config->{misc_limits}->{prio_throttling_data})) {
        if (
            my $mjt_info = _apply_max_job_time_prio(
                $settings->{TIMEOUT_SCALE},
                $settings->{MAX_JOB_TIME},
                $throttling->{MAX_JOB_TIME},
                $new_job_args
            ))
        {
            push @throttling_info, $mjt_info;
        }
        for my $resource (keys %$throttling) {
            next if (!defined $settings->{$resource} || $resource eq 'MAX_JOB_TIME');
            push @throttling_info,
              $resource . _update_priority($settings->{$resource}, $throttling->{$resource}, $new_job_args);
        }
    }
    if ($config && $group && (my $group_throttling = $config->{misc_limits}->{prio_group_data})) {
        for my $rule (@$group_throttling) {
            my $prop = $rule->{property};
            my $val = $group->$prop // '';
            if ($val =~ $rule->{regex}) {
                $new_job_args->{priority} += $rule->{increment};
                my $sign = $rule->{increment} >= 0 ? '+' : '';
                push @throttling_info, "$sign$rule->{increment} because job group $prop matches $rule->{regex}";
            }
        }
    }

    if (my $limits = $config ? $config->{misc_limits} : undef) {
        my $threshold = $limits->{throttle_failing_job_threshold};
        my $step = $limits->{throttle_failing_job_prio_step};
        my $history_length = $limits->{throttle_failing_job_history_length};
        if (   $threshold > 0
            && $step > 0
            && (my $failures = $self->_consecutive_failures($new_job_args, $history_length)) >= $threshold)
        {
            my $increment = $step * ($failures - $threshold + 1);
            $new_job_args->{priority} += $increment;
            push @throttling_info, sprintf '+%d because of %d consecutive failures in this scenario', $increment,
              $failures;
        }
    }
    if (@throttling_info) {
        my $info_str = join '; ', @throttling_info;
        $debug_msg = sprintf
          '- Adjusting job priority from %d to %d based on resource requirement(s): %s',
          $base_prio, $new_job_args->{priority}, $info_str;
    }
    return $debug_msg;
}

sub _consecutive_failures ($self, $job_args, $history_length) {
    my $conds = [
        {'me.state' => OpenQA::Jobs::Constants::DONE},
        {'me.result' => {-not_in => [OpenQA::Jobs::Constants::ABORTED_RESULTS]}},
        map { {"me.$_" => $job_args->{$_}} } OpenQA::Schema::Result::Jobs::SCENARIO_WITH_MACHINE_KEYS
    ];
    my $attrs = {order_by => ['me.id DESC'], rows => $history_length, select => [qw(me.id me.result)]};
    my @recent_jobs = $self->search({-and => $conds}, $attrs)->all;
    my $failures
      = List::Util::first { OpenQA::Jobs::Constants::is_ok_result($recent_jobs[$_]->result) } 0 .. $#recent_jobs;
    return $failures // scalar @recent_jobs;
}

sub _handle_dependency_settings ($self, $settings, $new_job_args) {
    my $job_settings = $self->result_source->schema->resultset('JobSettings');
    # handle dependencies
    # note: The subsequent code only allows adding existing jobs as parents. Hence it is not
    #       possible to create cyclic dependencies here.
    my @dependency_definitions = (
        {
            setting_name => '_START_AFTER_JOBS',
            dependency_type => OpenQA::JobDependencies::Constants::CHAINED,
        },
        {
            setting_name => '_START_DIRECTLY_AFTER_JOBS',
            dependency_type => OpenQA::JobDependencies::Constants::DIRECTLY_CHAINED,
        },
        {
            setting_name => '_PARALLEL_JOBS',
            dependency_type => OpenQA::JobDependencies::Constants::PARALLEL,
        },
    );
    for my $dependency_definition (@dependency_definitions) {
        next unless my $ids = delete $settings->{$dependency_definition->{setting_name}};

        # support array ref or comma separated values
        $ids = [split /\s*,\s*/, $ids] if ref $ids ne 'ARRAY';

        my $dependency_type = $dependency_definition->{dependency_type};
        for my $id (@$ids) {
            if ($dependency_type eq OpenQA::JobDependencies::Constants::DIRECTLY_CHAINED) {
                my $parent_worker_classes = join ',', @{$job_settings->all_values_sorted($id, 'WORKER_CLASS')};
                _handle_directly_chained_dep($parent_worker_classes, $id, $settings);
            }
            push @{$new_job_args->{parents}}, {parent_job_id => $id, dependency => $dependency_type};
        }
    }
}

sub _handle_directly_chained_dep ($parent_classes, $id, $settings) {
    # assume we want to use the worker class from the parent here (and not the default which is otherwise assumed)
    return $settings->{WORKER_CLASS} = $parent_classes unless defined(my $classes = $settings->{WORKER_CLASS});

    # raise error if the directly chained child has a different set of worker classes assigned than its parent
    die "Specified WORKER_CLASS ($classes) does not match the one from directly chained parent $id ($parent_classes)"
      unless $parent_classes eq join ',', sort split m/,/, $classes;
}

sub _search_modules ($self, $module_re) {
    my $distris = path(testcasedir);
    my @results;
    for my $distri ($distris->list({dir => 1})->map('realpath')->uniq()->each) {
        next unless -d $distri;

        my @cmd = ('git', '-C', $distri, 'grep', '--no-index', '-l', $module_re, '--', '*.p[my]');
        my $stdout;
        my $stderr;
        IPC::Run::run(\@cmd, \undef, \$stdout, \$stderr);
        next if $stderr;
        push @results, map { $_ =~ s/\..*$//; basename $_ } split /\n/, $stdout;
    }
    return \@results;
}

sub _prepare_complex_query_search_args ($self, $args) {
    my @conds;
    my @joins;
    my $job_settings = $args->{job_settings} // {};

    if ($args->{module_re}) {
        my $modules = $self->_search_modules($args->{module_re});
        push @{$args->{modules}}, @$modules;
    }

    if ($args->{modules}) {
        push @joins, 'modules';
        push @conds, {'modules.name' => {-in => $args->{modules}}};
    }
    if ($args->{modules_result}) {
        push @joins, 'modules' unless grep { 'modules' } @joins;
        push @conds, {'modules.result' => {-in => $args->{modules_result}}};
    }

    push @conds, {'me.state' => $args->{state}} if $args->{state};
    # allows explicit filtering, e.g. in query url "...&result=failed&result=incomplete"
    push @conds, {'me.result' => {-in => $args->{result}}} if $args->{result};
    push @conds, {'me.result' => {-not_in => [OpenQA::Jobs::Constants::NOT_COMPLETE_RESULTS]}}
      if $args->{ignore_incomplete};
    my $scope = $args->{scope} || '';
    if ($scope eq 'relevant') {
        push @joins, 'clone';
        push @conds, {
            -or => [
                'me.clone_id' => undef,
                'clone.state' => [OpenQA::Jobs::Constants::PENDING_STATES],
            ],
            'me.result' => {    # these results should be hidden by default
                -not_in => [OpenQA::Jobs::Constants::OBSOLETED]}};
    }
    push @conds, {'me.clone_id' => undef} if $scope eq 'current';
    push @conds, {'me.id' => {'<', $args->{before}}} if $args->{before};
    push @conds, {'me.id' => {'>', $args->{after}}} if $args->{after};
    my $rsource = $self->result_source;
    my $schema = $rsource->schema;

    if (defined $args->{groupids}) {
        push @conds, {'me.group_id' => {-in => $args->{groupids}}};
    }
    elsif (defined $args->{groupid}) {
        push @conds, {'me.group_id' => $args->{groupid} || undef};
    }
    elsif ($args->{group}) {
        my $subquery = $schema->resultset('JobGroups')->search({name => $args->{group}})->get_column('id')->as_query;
        push @conds, {'me.group_id' => {-in => $subquery}};
    }

    if (defined $args->{not_groupid}) {
        my $id = $args->{not_groupid};
        if ($id) {
            push @conds, {-or => [{'me.group_id' => {-not_in => $id}}, {'me.group_id' => undef},]};
        }
        else {
            push @conds, {'me.group_id' => {-not => undef}};
        }
    }
    if ($args->{ids}) {
        push @conds, {'me.id' => {-in => $args->{ids}}};
    }
    elsif ($args->{match}) {
        my @likes;
        # Text search across some settings
        push @likes, {"me.$_" => {'-like' => "%$args->{match}%"}} for (qw(DISTRI FLAVOR BUILD TEST VERSION));
        push @conds, -or => \@likes;
    }
    else {
        # Check if the settings are between the arguments passed via query url
        # they come in lowercase, so make sure $key is lc'ed
        for my $key (qw(ISO HDD_1 WORKER_CLASS)) {
            $job_settings->{$key} = $args->{lc $key} if defined $args->{lc $key};
        }
        for my $key (qw(distri version flavor arch test machine)) {
            push @conds, {'me.' . uc($key) => $args->{$key}} if $args->{$key};
        }
        if (my $build = $args->{build}) {
            push @conds, {'me.BUILD' => ref $build eq 'ARRAY' ? {-in => $build} : $build};
        }
    }

    push @conds, $schema->resultset('JobSettings')->conds_for_settings($job_settings) if keys %$job_settings;

    if (defined(my $c = $args->{comment_text})) {
        push @conds, \['(select id from comments where job_id = me.id and text like ? limit 1) is not null', "%$c%"];
    }

    push @conds, @{$args->{additional_conds}} if $args->{additional_conds};
    my %attrs;
    $attrs{columns} = $args->{columns} if $args->{columns};
    $attrs{prefetch} = $args->{prefetch} if $args->{prefetch};
    $attrs{rows} = $args->{limit} if $args->{limit};
    $attrs{offset} = $args->{offset} if $args->{offset};
    $attrs{order_by} = $args->{order_by} || ['me.id DESC'];
    $attrs{join} = \@joins if @joins;
    return (\@conds, \%attrs);
}

sub _accept_comma_separated_arg_values ($args) {
    for my $arg (qw(state ids result modules modules_result)) {
        next unless my $value = $args->{$arg};
        $args->{$arg} = [split /,/, $value] unless ref $value eq 'ARRAY';
    }
}

sub complex_query ($self, %args) {
    _accept_comma_separated_arg_values(\%args);
    my ($conds, $attrs) = $self->_prepare_complex_query_search_args(\%args);
    return $self->search({-and => $conds}, $attrs);
}

sub complex_query_latest_ids ($self, %args) {
    # prepare basic search conditions and attributes
    _accept_comma_separated_arg_values(\%args);
    my ($conds, $attrs) = $self->_prepare_complex_query_search_args(\%args);
    my $filters = $args{filters};
    my $has_filters = $filters && @$filters > 0;
    my $rows = $has_filters ? delete $attrs->{rows} : undef;  # when filtering, limit rows only in outer/filtering query
    if (my $until = $args{until}) { push @$conds, {'me.t_created' => {'<=' => $until}} }

    # set attributes to return only the latest job IDs for a certain combination of TEST, DISTRI, VERSION, …
    $attrs->{order_by} = \['max(me.id) DESC'];
    $attrs->{select} = ['max(me.id)'];
    $attrs->{as} = ['id'];
    $attrs->{group_by} = [OpenQA::Schema::Result::Jobs::MAIN_SETTINGS];

    # execute the search; use a sub query if filtering is enabled
    my $search = $self->search({-and => $conds}, $attrs);
    if ($has_filters) {
        # add another layer of querying for filters
        # note: The filtering cannot be applied in the same query we do the grouping to return only the latest job IDs.
        #       Otherwise adding filter parameters would lead to old jobs showing up. That is not wanted (and we have
        #       therefore the test "filtering does not reveal old jobs" in `10-tests_overview.t` to test this).
        my %filter_attrs = %$attrs;
        $filter_attrs{rows} = $rows;
        push @$filters, {'me.id' => {-in => $search->as_query}};
        $search = $self->search({-and => $filters}, \%filter_attrs);
    }
    return [map { $_->id } $search->all];
}

sub latest_jobs_from_ids ($self, $latest_job_ids, $limit_from_initial_search) {
    my %search_args = (id => {-in => $latest_job_ids});
    my %options = (order_by => {-desc => 'id'}, rows => $limit_from_initial_search - 1);
    return $self->search(\%search_args, \%options);
}

sub cancel_by_settings (
    $self, $settings,
    $newbuild = undef,
    $deprioritize = undef,
    $deprio_limit = undef,
    $related_scheduled_product = undef
  )
{
    $deprio_limit //= 100;
    my $schema = $self->result_source->schema;
    my %settings = %$settings;    # make copy to preserve original settings
    my %main_conds = (
        state => [PENDING_STATES],
        map { defined $settings{$_} ? ($_, delete $settings{$_}) : () } OpenQA::Schema::Result::Jobs::MAIN_SETTINGS,
    );
    my @setting_conds = keys %settings ? $schema->resultset('JobSettings')->conds_for_settings(\%settings) : ();
    my $jobs = $schema->resultset('Jobs')->search({-and => [\%main_conds, @setting_conds]});
    if ($newbuild) {
        # filter out all jobs that have any comment (they are considered 'important') ...
        my $jobs_without_comments = $jobs->search({'comments.job_id' => undef}, {join => 'comments'});
        # ... or belong to a tagged build, i.e. is considered important
        # this might be even the tag 'not important' but not much is lost if
        # we still not cancel these builds
        my $comments_search = {'me.group_id' => {-in => $jobs->get_column('group_id')->as_query}};
        my @important_builds = map { ($_->tag)[0] // () } $schema->resultset('Comments')->search($comments_search);
        my @unimportant_jobs;
        while (my $j = $jobs_without_comments->next) {
            # the value we get from that @important_builds search above
            # could be just BUILD or VERSION-BUILD
            next if grep { $j->BUILD eq $_ } @important_builds;
            next if grep { join('-', $j->VERSION, $j->BUILD) eq $_ } @important_builds;
            push @unimportant_jobs, $j->id;
        }
        # if there are only important jobs there is nothing left for us to do
        return 0 unless @unimportant_jobs;
        $jobs = $jobs->search({'me.id' => {-in => \@unimportant_jobs}});
    }
    my $cancelled_jobs = 0;
    my $priority_increment = 10;
    my $job_result = $newbuild ? OBSOLETED : USER_CANCELLED;
    my $reason
      = $related_scheduled_product
      ? 'cancelled by scheduled product ' . $related_scheduled_product->id
      : 'cancelled based on job settings';
    my $cancel_or_deprioritize = sub ($job) {
        if ($deprioritize) {
            my $prio = $job->priority + $priority_increment;
            if ($prio < $deprio_limit) {
                $job->set_prio($prio);
                return 0;
            }
        }
        return $job->cancel($job_result, $reason) // 0;
    };
    # first scheduled to avoid worker grab
    $cancelled_jobs += $cancel_or_deprioritize->($_) for $jobs->search({state => SCHEDULED});
    # then the rest
    $cancelled_jobs += $cancel_or_deprioritize->($_) for $jobs->search({state => [EXECUTION_STATES]});
    OpenQA::App->singleton->emit_event(openqa_job_cancel_by_settings => $settings) if $cancelled_jobs;
    return $cancelled_jobs;
}

sub next_previous_jobs_query ($self, $job, $jobid, %args) {
    my $p_limit = $args{previous_limit};
    my $n_limit = $args{next_limit};
    my @params = (
        'done',    # only consider jobs with state 'done'
        OpenQA::Jobs::Constants::ABORTED_RESULTS,    # ignore aborted results
    );
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


sub stale_ones ($self) {
    my $dt = DateTime->from_epoch(
        epoch => time() - OpenQA::App->singleton->config->{global}->{worker_timeout},
        time_zone => 'UTC'
    );
    my %dt_cond = ('<' => $self->result_source->schema->storage->datetime_parser->format_datetime($dt));
    my %overall_cond = (
        state => [OpenQA::Jobs::Constants::EXECUTION_STATES],
        assigned_worker_id => {-not => undef},
        -or => [
            'assigned_worker.t_seen' => undef,
            'assigned_worker.t_seen' => \%dt_cond,
        ],
    );
    my %attrs = (join => 'assigned_worker', order_by => 'job_id');
    return $self->search(\%overall_cond, \%attrs);
}

sub mark_job_linked ($self, $jobid, $referer_url) {
    my $referer = Mojo::URL->new($referer_url);
    my $referer_host = $referer->host;
    my $app = OpenQA::App->singleton;
    return undef unless $referer_host;
    return log_trace("Unrecognized referer '$referer_host'")
      unless grep { $referer_host eq $_ } @{$app->config->{global}->{recognized_referers}};
    my $job = $self->find({id => $jobid});
    return undef if !$job || ($referer->path_query =~ /^\/?$/);
    my $comments = $job->comments;
    return undef if $comments->search({text => {like => 'label:linked%'}}, {rows => 1})->first;
    return undef unless my $user = $self->result_source->schema->resultset('Users')->system({select => ['id']});
    my $bugref = href_to_bugref($referer_url);
    my $label = $referer_url eq $bugref ? "label:linked $referer" : "label:linked:$bugref";
    $comments->create_with_event({text => "$label mentions this job", user_id => $user->id});
}

sub ancestors_count_for_jobs ($self, $job_ids) {
    return {} unless $job_ids && @$job_ids;
    my $dbh = $self->result_source->schema->storage->dbh;
    my $sth = $dbh->prepare(<<~'SQL');
        with recursive orig_id as (
            select id as initial_id, id as orig_id, 0 as level from jobs where id = ANY(?)
            union all
            select initial_id, jobs.id as orig_id, orig_id.level + 1 as level
            from jobs
            join orig_id on orig_id.orig_id = jobs.clone_id
            where orig_id.level < 100
        )
        select initial_id, max(level) from orig_id group by initial_id;
    SQL
    $sth->execute($job_ids);
    my %result;
    while (my ($id, $level) = $sth->fetchrow_array) {
        $result{$id} = $level;
    }
    return \%result;
}

1;
