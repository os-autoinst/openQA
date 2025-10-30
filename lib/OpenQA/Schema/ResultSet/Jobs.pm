# Copyright 2014-2021 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Schema::ResultSet::Jobs;

use Mojo::Base 'DBIx::Class::ResultSet', -signatures;
use DBIx::Class::Timestamps 'now';
use Date::Format 'time2str';
use Encode qw(decode_utf8);
use File::Basename 'basename';
use IPC::Run;
use OpenQA::App;
use OpenQA::Jobs::Constants;
use OpenQA::Log qw(log_trace log_debug log_info);
use OpenQA::Schema::Result::Jobs;
use OpenQA::Schema::Result::JobDependencies;
use OpenQA::Utils 'testcasedir';
use Mojo::File 'path';
use Mojo::JSON 'encode_json';
use Mojo::URL;
use Mojolicious::Validator;
use Mojolicious::Validator::Validation;
use Time::HiRes 'time';
use DateTime;

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
    push(@conds, {'me.group_id' => $groupid}) if defined $groupid;

    $attrs{join} = 'settings';
    $attrs{rows} = 1;
    $attrs{order_by} = {-desc => 'me.id'};    # More reliable for tests than t_created
    $attrs{columns} = qw(BUILD);

    foreach my $key (keys %args) {
        my $value = $args{$key};

        if (grep { $key eq $_ } qw(distri version flavor machine arch build test)) {
            push(@conds, {'me.' . uc($key) => $value});
        }
        else {

            my $subquery = $schema->resultset('JobSettings')->search(
                {
                    key => uc($key),
                    value => $value
                });
            push(@conds, {'me.id' => {-in => $subquery->get_column('job_id')->as_query}});
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
        my $test = $job->TEST;
        my $distri = $job->DISTRI;
        my $version = $job->VERSION;
        my $build = $job->BUILD;
        my $flavor = $job->FLAVOR;
        my $arch = $job->ARCH;
        my $machine = $job->MACHINE // '';
        my $key = "$distri-$version-$build-$test-$flavor-$arch-$machine";
        next if $seen{$key}++;
        push(@latest, $job);
    }

    return @latest;
}

sub create_from_settings ($self, $settings, $scheduled_product_id = undef) {
    my %settings = %$settings;
    my %new_job_args;

    my $result_source = $self->result_source;
    my $schema = $result_source->schema;
    my $job_settings = $schema->resultset('JobSettings');

    my @invalid_keys = grep { $_ =~ /^(PUBLISH_HDD|FORCE_PUBLISH_HDD|STORE_HDD)\S+(\d+)$/ && $settings{$_} =~ /\// }
      keys %settings;
    die 'The ' . join(',', @invalid_keys) . " cannot include / in value\n" if @invalid_keys;

    # validate special settings
    my %special_settings = (TEST => delete $settings{TEST}, _PRIORITY => delete $settings{_PRIORITY});
    my $validator = Mojolicious::Validator->new;
    my $v = Mojolicious::Validator::Validation->new(validator => $validator, input => \%special_settings);
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
        next unless my $ids = delete $settings{$dependency_definition->{setting_name}};

        # support array ref or comma separated values
        $ids = [split(/\s*,\s*/, $ids)] if (ref($ids) ne 'ARRAY');

        my $dependency_type = $dependency_definition->{dependency_type};
        for my $id (@$ids) {
            if ($dependency_type eq OpenQA::JobDependencies::Constants::DIRECTLY_CHAINED) {
                my $parent_worker_classes = join(',', @{$job_settings->all_values_sorted($id, 'WORKER_CLASS')});
                _handle_directly_chained_dep($parent_worker_classes, $id, \%settings);
            }
            push(@{$new_job_args{parents}}, {parent_job_id => $id, dependency => $dependency_type});
        }
    }

    for my $key (keys %settings) {
        my $value = $settings{$key};
        $settings{$key} = decode_utf8 encode_json $value if (ref $value eq 'ARRAY' || ref $value eq 'HASH');
    }

    # move important keys from the settings directly to the job
    $new_job_args{TEST} = $test;
    for my $key (OpenQA::Schema::Result::Jobs::MAIN_SETTINGS) {
        if (my $value = delete $settings{$key}) { $new_job_args{$key} = $value }
    }

    # assign default for WORKER_CLASS
    $settings{WORKER_CLASS} ||= 'qemu_' . ($new_job_args{ARCH} // 'x86_64');

    # assign scheduled product
    $new_job_args{scheduled_product_id} = $scheduled_product_id;

    my $job = $self->create(\%new_job_args);

    # add job settings
    my @job_settings;
    my $now = now;
    for my $key (keys %settings) {
        my @values = $key =~ qr/(^WORKER_CLASS|\[\])$/ ? split(m/,/, $settings{$key}) : ($settings{$key});
        push(@job_settings, {t_created => $now, t_updated => $now, key => $key, value => $_}) for @values;
    }
    $job->settings->populate(\@job_settings);

    # associate currently available assets with job
    $job->register_assets_from_settings;

    log_info('Ignoring invalid group ' . encode_json($group_args) . ' when creating new job ' . $job->id)
      if keys %$group_args && !$group;
    $job->calculate_blocked_by;
    return $job;
}

sub _handle_directly_chained_dep ($parent_classes, $id, $settings) {
    # assume we want to use the worker class from the parent here (and not the default which is otherwise assumed)
    return $settings->{WORKER_CLASS} = $parent_classes unless defined(my $classes = $settings->{WORKER_CLASS});

    # raise error if the directly chained child has a different set of worker classes assigned than its parent
    die "Specified WORKER_CLASS ($classes) does not match the one from directly chained parent $id ($parent_classes)"
      unless $parent_classes eq join(',', sort split(m/,/, $classes));
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
        push(@results, map { $_ =~ s/\..*$//; basename $_ } split(/\n/, $stdout));
    }
    return \@results;
}

sub _prepare_complex_query_search_args ($self, $args) {
    my @conds;
    my @joins;

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

    push(@conds, {'me.state' => $args->{state}}) if $args->{state};
    # allows explicit filtering, e.g. in query url "...&result=failed&result=incomplete"
    push(@conds, {'me.result' => {-in => $args->{result}}}) if $args->{result};
    push(@conds, {'me.result' => {-not_in => [OpenQA::Jobs::Constants::NOT_COMPLETE_RESULTS]}})
      if $args->{ignore_incomplete};
    my $scope = $args->{scope} || '';
    if ($scope eq 'relevant') {
        push(@joins, 'clone');
        push @conds, {
            -or => [
                'me.clone_id' => undef,
                'clone.state' => [OpenQA::Jobs::Constants::PENDING_STATES],
            ],
            'me.result' => {    # these results should be hidden by default
                -not_in => [OpenQA::Jobs::Constants::OBSOLETED]}};
    }
    push(@conds, {'me.clone_id' => undef}) if $scope eq 'current';
    push(@conds, {'me.id' => {'<', $args->{before}}}) if $args->{before};
    push(@conds, {'me.id' => {'>', $args->{after}}}) if $args->{after};
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
        push(@likes, {"me.$_" => {'-like' => "%$args->{match}%"}}) for (qw(DISTRI FLAVOR BUILD TEST VERSION));
        push(@conds, -or => \@likes);
    }
    else {
        my %js_settings;
        # Check if the settings are between the arguments passed via query url
        # they come in lowercase, so mace sure $key is lc'ed
        for my $key (qw(ISO HDD_1 WORKER_CLASS)) {
            $js_settings{$key} = $args->{lc $key} if defined $args->{lc $key};
        }
        if (keys %js_settings) {
            my $subquery = $schema->resultset('JobSettings')->query_for_settings(\%js_settings);
            push(@conds, {'me.id' => {-in => $subquery->get_column('job_id')->as_query}});
        }

        for my $key (qw(distri version flavor arch test machine)) {
            push(@conds, {'me.' . uc($key) => $args->{$key}}) if $args->{$key};
        }
        if (my $build = $args->{build}) {
            push @conds, {'me.BUILD' => ref $build eq 'ARRAY' ? {-in => $build} : $build};
        }
    }

    if (defined(my $c = $args->{comment_text})) {
        push @conds, \['(select id from comments where job_id = me.id and text like ? limit 1) is not null', "%$c%"];
    }

    push(@conds, @{$args->{additional_conds}}) if $args->{additional_conds};
    my %attrs;
    $attrs{columns} = $args->{columns} if $args->{columns};
    $attrs{prefetch} = $args->{prefetch} if $args->{prefetch};
    $attrs{rows} = $args->{limit} if $args->{limit};
    $attrs{offset} = $args->{offset} if $args->{offset};
    $attrs{order_by} = $args->{order_by} || ['me.id DESC'];
    $attrs{join} = \@joins if @joins;
    return (\@conds, \%attrs);
}

sub complex_query ($self, %args) {
    # For args where we accept a list of values, allow passing either an
    # array ref or a comma-separated list
    for my $arg (qw(state ids result modules modules_result)) {
        next unless $args{$arg};
        $args{$arg} = [split(',', $args{$arg})] unless (ref($args{$arg}) eq 'ARRAY');
    }
    my ($conds, $attrs) = $self->_prepare_complex_query_search_args(\%args);
    my $jobs = $self->search({-and => $conds}, $attrs);
    return $jobs;
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
    my $rsource = $self->result_source;
    my $schema = $rsource->schema;
    # preserve original settings by deep copy
    my %precond = %{$settings};
    my %cond;

    for my $key (qw(DISTRI VERSION FLAVOR MACHINE ARCH BUILD TEST)) {
        $cond{$key} = delete $precond{$key} if defined $precond{$key};
    }
    if (keys %precond) {
        my $subquery = $schema->resultset('JobSettings')->query_for_settings(\%precond);
        $cond{'me.id'} = {-in => $subquery->get_column('job_id')->as_query};
    }
    $cond{state} = [OpenQA::Jobs::Constants::PENDING_STATES];
    my $jobs = $schema->resultset('Jobs')->search(\%cond);
    my $jobs_to_cancel;
    if ($newbuild) {
        # filter out all jobs that have any comment (they are considered 'important') ...
        $jobs_to_cancel = $jobs->search({'comments.job_id' => undef}, {join => 'comments'});
        # ... or belong to a tagged build, i.e. is considered important
        # this might be even the tag 'not important' but not much is lost if
        # we still not cancel these builds
        my $groups_query = $jobs->get_column('group_id')->as_query;
        my @important_builds = grep defined,
          map { ($_->tag)[0] } $schema->resultset('Comments')->search({'me.group_id' => {-in => $groups_query}});
        my @unimportant_jobs;
        while (my $j = $jobs_to_cancel->next) {
            # the value we get from that @important_builds search above
            # could be just BUILD or VERSION-BUILD
            next if grep ($j->BUILD eq $_, @important_builds);
            next if grep (join('-', $j->VERSION, $j->BUILD) eq $_, @important_builds);
            push @unimportant_jobs, $j->id;
        }
        # if there are only important jobs there is nothing left for us to do
        return 0 unless @unimportant_jobs;
        $jobs_to_cancel = $jobs_to_cancel->search({'me.id' => {-in => \@unimportant_jobs}});
    }
    else {
        $jobs_to_cancel = $jobs;
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
    my $scheduled = $jobs_to_cancel->search({state => SCHEDULED});
    $cancelled_jobs += $cancel_or_deprioritize->($_) for $scheduled->all;
    # then the rest
    my $executing = $jobs_to_cancel->search({state => [OpenQA::Jobs::Constants::EXECUTION_STATES]});
    $cancelled_jobs += $cancel_or_deprioritize->($_) for $executing->all;
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
    return undef unless _specific_issue_exists($referer);
    my $job = $self->find({id => $jobid});
    return undef if !$job || ($referer->path_query =~ /^\/?$/);
    my $comments = $job->comments;
    return undef if $comments->search({text => {like => 'label:linked%'}}, {rows => 1})->first;
    my $user = $self->result_source->schema->resultset('Users')->system({select => ['id']});
    $comments->create_with_event({text => "label:linked Job mentioned in $referer_url", user_id => $user->id});
}

sub _specific_issue_exists ($url) {
    my $path = $url->path();
    my ($issue_id) = $path =~ m/(?:id=|\/)(\d+)/;
    # Assume that the url is valid if there is issue_id
    return defined $issue_id;
}

1;
