# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::WebAPI::Plugin::MCP;
use Mojo::Base 'Mojolicious::Plugin', -signatures;

use MCP::Server;
use Mojo::Template;
use Mojo::Loader qw(data_section);
use Mojo::File qw(path);
use Mojo::Parameters;
use Mojo::Transaction::HTTP;
use Feature::Compat::Try;
use List::Util 'first';
use Mojo::JSON 'encode_json';

my %TOOLS = (
    openqa_get_info => {
        title => 'Get openQA Server Info',
        mode => 'read-only',
        scopes => ['mcp:read'],
        annotations => {readOnlyHint => \1, destructiveHint => \0, idempotentHint => \1, openWorldHint => \0},
        description => 'Get information about the openQA server, connected workers and the current user',
        properties => {},
        call => \&tool_openqa_get_info,
    },
    openqa_get_job_info => {
        title => 'Get openQA Job Details',
        mode => 'read-only',
        scopes => ['mcp:read'],
        annotations => {readOnlyHint => \1, destructiveHint => \0, idempotentHint => \1, openWorldHint => \0},
        description => 'Get any information about a specific openQA job, like logs, scheduling etc.',
        properties =>
          {job_id => {type => 'integer', minimum => 1, description => 'The job ID of any openQA test suite.'}},
        required => ['job_id'],
        call => \&tool_openqa_get_job_info,
    },
    openqa_get_log_file => {
        title => 'Get openQA Job Log File',
        mode => 'read-only',
        scopes => ['mcp:read'],
        annotations => {readOnlyHint => \1, destructiveHint => \0, idempotentHint => \1, openWorldHint => \0},
        description => 'Get the content of a specific log file for an openQA job',
        properties => {
            job_id => {type => 'integer', minimum => 1, description => 'The job ID of the openQA job'},
            file_name => {
                type => 'string',
                minLength => 1,
                description =>
                  'Name of the log file to lookup (e.g., autoinst-log.txt, serial0.txt). Only text logs for now'
            }
        },
        required => ['job_id', 'file_name'],
        call => \&tool_openqa_get_log_file,
    },
    openqa_list_jobs => {
        title => 'List openQA Jobs',
        mode => 'read-only',
        scopes => ['mcp:read'],
        annotations => {readOnlyHint => \1, destructiveHint => \0, idempotentHint => \1, openWorldHint => \0},

        description => 'List jobs filtered by group, state, result, test name, distri, version, build, arch, flavor '
          . 'or machine. Use latest=1 for the most recent job per test setting combination and scope=relevant for '
          . 'pending, non-obsoleted jobs.',
        properties => {
            groupid => {type => 'integer', minimum => 1, description => 'Job group ID to filter by'},
            state => {
                type => 'string',
                description => 'Job state, e.g. scheduled, running, done; comma-separated for multiple'
            },
            result =>
              {type => 'string', description => 'Job result, e.g. passed, failed; comma-separated for multiple'},
            test => {type => 'string', description => 'TEST setting to filter by'},
            distri => {type => 'string'},
            version => {type => 'string'},
            build => {type => 'string'},
            arch => {type => 'string'},
            flavor => {type => 'string'},
            machine => {type => 'string'},
            latest => {type => 'boolean', description => 'Return only the latest job per test setting combination'},
            scope => {
                type => 'string',
                enum => ['current', 'relevant'],
                description => 'current excludes clones, relevant includes only pending jobs'
            },
            limit => {
                type => 'integer',
                minimum => 1,
                description => 'Maximum number of jobs, capped by the server configuration'
            },
            offset => {type => 'integer', minimum => 0},
        },
        output_schema => {type => 'object'},
        call => sub ($tool, $args) {
            _call(
                $tool,
                role => 'user',
                controller => 'Job',
                action => 'list',
                method => 'GET',
                path => '/api/v1/jobs',
                params => _params($args));
        },
    },
    openqa_list_job_groups => {
        title => 'List openQA Job Groups',
        mode => 'read-only',
        scopes => ['mcp:read'],
        annotations => {readOnlyHint => \1, destructiveHint => \0, idempotentHint => \1, openWorldHint => \0},

        description =>
          'List all job groups with their properties, or one group given its ID. Set parent=1 to list parent groups.',
        properties => {
            group_id => {type => 'integer', minimum => 1, description => 'Limit the result to one group'},
            parent => {type => 'boolean', description => 'List parent groups instead of job groups'},
        },
        output_schema => {type => 'array', items => {type => 'object'}},
        call => sub ($tool, $args) {
            my $parent = delete $args->{parent};
            _call(
                $tool,
                role => 'user',
                controller => 'JobGroup',
                action => 'list',
                method => 'GET',
                path => ($parent ? '/api/v1/parent_groups' : '/api/v1/job_groups'),
                params => _params($args));
        },
    },
    openqa_job_group_overview => {
        title => 'openQA Job Group Build Results',
        mode => 'read-only',
        scopes => ['mcp:read'],
        annotations => {readOnlyHint => \1, destructiveHint => \0, idempotentHint => \1, openWorldHint => \0},

        description =>
          'Build results of a job group: the latest builds with their job counts, like the group overview page.',
        properties => {
            group_id => {type => 'integer', minimum => 1, description => 'Job group ID'},
            limit_builds => {type => 'integer', minimum => 1, description => 'Number of builds to include, default 10'},
            time_limit_days => {type => 'number', description => 'Include only builds of the last N days'},
            only_tagged => {type => 'boolean'},
            show_tags => {type => 'boolean'},
        },
        required => ['group_id'],
        output_schema => {type => 'object'},
        call => sub ($tool, $args) {
            my $group_id = delete $args->{group_id};
            _call(
                $tool,
                role => 'user',
                controller => 'JobGroup',
                action => 'build_results',
                method => 'GET',
                path => "/api/v1/job_groups/$group_id/build_results",
                captures => {group_id => $group_id},
                params => _params($args));
        },
    },
    openqa_list_workers => {
        title => 'List openQA Workers',
        mode => 'read-only',
        scopes => ['mcp:read'],
        annotations => {readOnlyHint => \1, destructiveHint => \0, idempotentHint => \1, openWorldHint => \0},

        description =>
          'List all workers with their status (idle, running, reserved, broken, dead), assigned job and reservation.',
        properties => {},
        output_schema => {type => 'array', items => {type => 'object'}},
        call => sub ($tool, $args) {
            _structured($tool, [map { $_->info } _get_schema($tool)->resultset('Workers')->all]);
        },
    },
    openqa_get_comments => {
        title => 'Get openQA Comments',
        mode => 'read-only',
        scopes => ['mcp:read'],
        annotations => {readOnlyHint => \1, destructiveHint => \0, idempotentHint => \1, openWorldHint => \0},

        description => 'List comments of a job, a job group or a parent group.',
        properties => {
            job_id => {type => 'integer', minimum => 1},
            group_id => {type => 'integer', minimum => 1},
            parent_group_id => {type => 'integer', minimum => 1},
            limit => {type => 'integer', minimum => 1},
            render_markdown => {type => 'boolean'},
        },
        output_schema => {type => 'array', items => {type => 'object'}},
        call => sub ($tool, $args) {
            _call(
                $tool,
                role => 'user',
                controller => 'Comment',
                action => 'list',
                method => 'GET',
                path => '/api/v1/comments',
                params => _params($args));
        },
    },
    openqa_search => {
        title => 'Search openQA Tests',
        mode => 'read-only',
        scopes => ['mcp:read'],
        annotations => {readOnlyHint => \1, destructiveHint => \0, idempotentHint => \1, openWorldHint => \0},

        description => 'Search for tests by keyword, e.g. a test name, distri, version or build.',
        properties => {q => {type => 'string', minLength => 1, description => 'One or more keywords'}},
        required => ['q'],
        output_schema => {type => 'object'},
        call => sub ($tool, $args) {
            _call(
                $tool,
                role => 'user',
                controller => 'Search',
                action => 'query',
                method => 'GET',
                path => '/api/v1/experimental/search',
                params => [q => $args->{q}]);
        },
    },
    openqa_list_api_routes => {
        title => 'List openQA API Routes',
        mode => 'read-only',
        scopes => ['mcp:read'],
        annotations => {readOnlyHint => \1, destructiveHint => \0, idempotentHint => \1, openWorldHint => \0},

        description => 'List all REST API routes of this openQA instance.',
        properties => {},
        output_schema => {type => 'object'},
        call => sub ($tool, $args) {
            _call(
                $tool,
                role => 'user',
                controller => 'Routes',
                action => 'list',
                method => 'GET',
                path => '/api/v1/routes'
            );
        },
    },
    openqa_trigger_job => {
        title => 'Trigger openQA Jobs',
        mode => 'read-write',
        scopes => ['mcp:write'],
        annotations => {readOnlyHint => \0, destructiveHint => \0, idempotentHint => \0, openWorldHint => \1},
        description => 'Trigger jobs by passing job settings, e.g. DISTRI, VERSION, BUILD, TEST. Use _FROM to clone '
          . 'the settings of an existing job like openqa-clone-job does, and _GROUP to place the new job in a group.',
        properties => {
            settings => {
                type => 'object',
                description => 'Job settings to trigger, keys like DISTRI, TEST, _FROM, _GROUP',
                additionalProperties => {type => 'string'},
            },
        },
        required => ['settings'],
        output_schema => {type => 'object'},
        call => sub ($tool, $args) {
            _call(
                $tool,
                role => 'operator',
                controller => 'Job',
                action => 'create',
                method => 'POST',
                path => '/api/v1/jobs',
                params => _params($args->{settings}));
        },
    },
    openqa_restart_job => {
        title => 'Restart openQA Job',
        mode => 'read-write',
        scopes => ['mcp:write'],
        annotations => {readOnlyHint => \0, destructiveHint => \0, idempotentHint => \0, openWorldHint => \0},
        description => 'Restart a job, optionally overriding job settings, forcing it despite missing assets, '
          . 'skipping parents or children, and adding a comment.',
        properties => {
            job_id => {type => 'integer', minimum => 1, description => 'Job ID to restart'},
            settings =>
              {type => 'object', description => 'Job settings to override', additionalProperties => {type => 'string'}},
            comment => {type => 'string'},
            prio => {type => 'integer', minimum => 0},
            force => {type => 'boolean', description => 'Restart despite missing assets'},
            skip_parents => {type => 'boolean'},
            skip_children => {type => 'boolean'},
            confirm => {type => 'boolean', description => 'Proceed without asking for confirmation'},
        },
        required => ['job_id'],
        output_schema => {type => 'object'},
        call => sub ($tool, $args) { _restart_call($tool, 'restart', $args); },
    },
    openqa_duplicate_job => {
        title => 'Duplicate openQA Job',
        mode => 'read-write',
        scopes => ['mcp:write'],
        annotations => {readOnlyHint => \0, destructiveHint => \0, idempotentHint => \0, openWorldHint => \0},
        description => 'Duplicate a job without aborting a running job, optionally overriding job settings.',
        properties => {
            job_id => {type => 'integer', minimum => 1, description => 'Job ID to duplicate'},
            settings =>
              {type => 'object', description => 'Job settings to override', additionalProperties => {type => 'string'}},
            comment => {type => 'string'},
            prio => {type => 'integer', minimum => 0},
            confirm => {type => 'boolean', description => 'Proceed without asking for confirmation'},
        },
        required => ['job_id'],
        output_schema => {type => 'object'},
        call => sub ($tool, $args) { _restart_call($tool, 'duplicate', $args); },
    },
    openqa_cancel_job => {
        title => 'Cancel openQA Job',
        mode => 'read-write',
        scopes => ['mcp:write'],
        annotations => {readOnlyHint => \0, destructiveHint => \1, idempotentHint => \0, openWorldHint => \0},
        description => 'Cancel a running or pending job. The result of the job is lost.',
        properties => {
            job_id => {type => 'integer', minimum => 1},
            reason => {type => 'string', description => 'Reason recorded in the job comment'},
            confirm => {type => 'boolean', description => 'Proceed without asking for confirmation'},
        },
        required => ['job_id'],
        output_schema => {type => 'object'},
        call => sub ($tool, $args) {
            my $job_id = delete $args->{job_id};
            my $confirmed = _confirm($tool, $args, 'Cancel job ' . $job_id . '?');
            return $confirmed if ref $confirmed;
            _call(
                $tool,
                role => 'operator',
                controller => 'Job',
                action => 'cancel',
                method => 'POST',
                path => "/api/v1/jobs/$job_id/cancel",
                captures => {jobid => $job_id},
                params => _params($args));
        },
    },
    openqa_set_job_priority => {
        title => 'Set openQA Job Priority',
        mode => 'read-write',
        scopes => ['mcp:write'],
        annotations => {readOnlyHint => \0, destructiveHint => \0, idempotentHint => \1, openWorldHint => \0},
        description => 'Change the priority of a job; a lower number is scheduled earlier.',
        properties => {
            job_id => {type => 'integer', minimum => 1},
            prio => {type => 'integer', minimum => 0, description => 'New priority'},
        },
        required => ['job_id', 'prio'],
        output_schema => {type => 'object'},
        call => sub ($tool, $args) {
            my $job_id = delete $args->{job_id};
            _call(
                $tool,
                role => 'operator',
                controller => 'Job',
                action => 'prio',
                method => 'POST',
                path => "/api/v1/jobs/$job_id/prio",
                captures => {jobid => $job_id},
                params => _params($args));
        },
    },
    openqa_post_comment => {
        title => 'Post openQA Comment',
        mode => 'read-write',
        scopes => ['mcp:read'],
        annotations => {readOnlyHint => \0, destructiveHint => \0, idempotentHint => \0, openWorldHint => \0},
        description => 'Add a comment to a job, a job group or a parent group. The REST API allows any logged-in '
          . 'user, so this tool is available without operator rights.',
        properties => {
            job_id => {type => 'integer', minimum => 1},
            group_id => {type => 'integer', minimum => 1},
            parent_group_id => {type => 'integer', minimum => 1},
            text => {type => 'string', minLength => 1, description => 'Bugrefs like bsc#1234 are turned into links'},
        },
        required => ['text'],
        output_schema => {type => 'object'},
        call => sub ($tool, $args) {
            my $job_id = $args->{job_id};
            _call(
                $tool,
                role => 'user',
                controller => 'Comment',
                action => 'create',
                method => 'POST',
                path => ($job_id ? "/api/v1/jobs/$job_id/comments" : '/api/v1/comments'),
                params => _params($args));
        },
    },
    openqa_schedule_iso => {
        title => 'Schedule openQA ISO',
        mode => 'read-write',
        scopes => ['mcp:write'],
        annotations => {readOnlyHint => \0, destructiveHint => \0, idempotentHint => \0, openWorldHint => \1},
        description => 'Schedule an ISO build, i.e. create the jobs defined by the job templates of its group. '
          . 'DISTRI, VERSION, FLAVOR and ARCH are mandatory. Scheduling runs asynchronously by default.',
        properties => {
            settings => {
                type => 'object',
                description =>
                  'Parameters of the scheduled product, e.g. DISTRI, VERSION, FLAVOR, ARCH, BUILD, ISO, REPO',
                additionalProperties => {type => 'string'},
            },
            scheduled_product_clone_id => {
                type => 'integer',
                minimum => 1,
                description => 'Reuse the settings of a previous scheduled product'
            },
            async => {type => 'boolean', description => 'Schedule as a Minion job, which is the default'},
            confirm => {type => 'boolean', description => 'Proceed without asking for confirmation'},
        },
        required => ['settings'],
        output_schema => {type => 'object'},
        call => sub ($tool, $args) {
            my $confirmed = _confirm($tool, $args, 'Schedule jobs for this build?');
            return $confirmed if ref $confirmed;
            my $params = _params(delete $args->{settings});
            push @$params, async => 1 unless delete $args->{async};
            push @$params, _params($args);
            _call(
                $tool,
                role => 'operator',
                controller => 'Iso',
                action => 'create',
                method => 'POST',
                path => '/api/v1/isos',
                params => $params
            );
        },
    },
);

my @RESOURCES = (
    {
        name => 'openqa_recent_jobs',
        uri => 'openqa://jobs/recent',
        title => 'Recent openQA Jobs',
        description => 'The 20 most recent jobs with state, result and job group',
        code => sub ($res) {
            _resource_json(
                $res,
                controller => 'Job',
                action => 'list',
                method => 'GET',
                path => '/api/v1/jobs',
                params => [limit => 20]);
        },
    },
    {
        name => 'openqa_job_groups',
        uri => 'openqa://job-groups',
        title => 'openQA Job Groups',
        description => 'All job groups with their properties',
        code => sub ($res) {
            _resource_json(
                $res,
                controller => 'JobGroup',
                action => 'list',
                method => 'GET',
                path => '/api/v1/job_groups'
            );
        },
    },
    {
        name => 'openqa_workers',
        uri => 'openqa://workers',
        title => 'openQA Workers',
        description => 'All workers with their status, assigned job and reservation',
        code => sub ($res) {
            $res->text_resource(encode_json([map { $_->info } _get_schema($res)->resultset('Workers')->all]));
        },
    },
);

my @PROMPTS = (
    {
        name => 'triage_job',
        description => 'Analyse why an openQA job failed and how to triage it',
        arguments => [{name => 'job_id', required => \1, description => 'Job ID to triage'}],
        code => sub ($prompt, $args) {
            my $job = _get_schema($prompt)->resultset('Jobs')->find($args->{job_id});
            return $prompt->text_prompt("Job $args->{job_id} not found") unless $job;
            my $summary = sprintf 'Triage openQA job %d (%s, state %s, result %s).',
              $args->{job_id}, $job->settings->{TEST} // 'unknown', $job->state, $job->result;
            return $prompt->text_prompt($summary . "\n"
                  . 'Read its comments with openqa_get_comments, its autoinst-log.txt with openqa_get_log_file and '
                  . 'its details with openqa_get_job_info. Report the failure reason, whether it is a known '
                  . 'infrastructure or packaging problem, and which action to take next.');
        },
    },
    {
        name => 'triage_build',
        description => 'Summarise the job results of an openQA build in a job group',
        arguments => [
            {name => 'group_id', required => \1, description => 'Job group ID'},
            {name => 'build', required => \1, description => 'Build version to look at'},
        ],
        code => sub ($prompt, $args) {
            my $res = _api_call(
                $prompt,
                role => 'user',
                controller => 'JobGroup',
                action => 'build_results',
                method => 'GET',
                path => "/api/v1/job_groups/$args->{group_id}/build_results",
                captures => {group_id => $args->{group_id}});
            return $prompt->text_prompt($res->{error}) if $res->{error};
            my $build = first { $_->{build} eq $args->{build} } @{$res->{json}{build_results}};
            return $prompt->text_prompt("Build $args->{build} not found in job group $args->{group_id}") unless $build;
            return $prompt->text_prompt(
                    "Summarise build $args->{build} of job group $args->{group_id} with the job counts below, name the "
                  . 'tests that failed most often and suggest which jobs to restart.
' . encode_json($build));
        },
    },
);

sub register ($self, $app, $config) {
    my $mode = $config->{mode} // 'read-only';
    my $mcp = MCP::Server->new;
    $mcp->name('openQA');
    $mcp->version('1.0.0');

    $mcp->instructions(
            'openQA provides read tools for jobs, job groups, workers, comments and search. On a server with '
          . 'mcp_enabled=read-write it also provides write tools for jobs, comments and ISO scheduling, which '
          . 'require operator rights. Destructive calls ask for confirmation before they are executed.');

    for my $resource (@RESOURCES) {
        $mcp->resource(%$resource);
    }
    for my $prompt (@PROMPTS) {
        $mcp->prompt(%$prompt);
    }

    for my $name (sort keys %TOOLS) {
        my $def = $TOOLS{$name};
        next if $def->{mode} eq 'read-write' && $mode ne 'read-write';
        $mcp->tool(
            name => $name,
            title => $def->{title},
            description => $def->{description},
            input_schema => {
                type => 'object',
                properties => $def->{properties},
                ($def->{required} ? (required => $def->{required}) : ()),
                additionalProperties => \0,
            },
            ($def->{output_schema} ? (output_schema => $def->{output_schema}) : ()),
            scopes => $def->{scopes},
            annotations => {title => $def->{title}, %{$def->{annotations}}},
            code => $def->{call},
        );
    }

    my %transport = (auth => sub ($c) { _auth_scopes($c, $mode) });
    $transport{origins} = [split ' ', $config->{origins}] if $config->{origins};
    my $mcp_auth = $app->routes->under('/')->to('Auth#auth')->name('mcp_ensure_user');
    $mcp_auth->any('/mcp' => $mcp->to_action(\%transport))->name('mcp');
}

# openQA roles are the authorization basis, so scopes are derived from them
# instead of being negotiated separately
sub _auth_scopes ($c, $mode) {
    my $user = $c->stash->{current_user}{user};
    my @scopes = ('mcp:read');
    if ($mode eq 'read-write') {
        push @scopes, 'mcp:write' if $user->is_operator;
        push @scopes, 'mcp:admin' if $user->is_admin;
    }
    return {scopes => \@scopes, principal => $user->username};
}

sub tool_openqa_get_info ($tool, $args) {
    my $c = _get_controller($tool);
    my $user = _get_user($tool);
    my $schema = _get_schema($tool);

    my $worker_stats = $schema->resultset('Workers')->stats;
    my $vars = {
        app_name => $c->stash->{appname},
        app_version => $c->stash->{current_version} // 'n/a',
        user_name => $user->name,
        user_id => $user->id,
        is_admin => $user->is_admin ? 'yes' : 'no',
        is_operator => $user->is_operator ? 'yes' : 'no',
        workers_total => $worker_stats->{total},
        workers_total_online => $worker_stats->{total_online},
        workers_offline => $worker_stats->{total} - $worker_stats->{total_online},
        active_workers => $worker_stats->{free_active_workers},
        broken_workers => $worker_stats->{free_broken_workers},
        busy_workers => $worker_stats->{busy_workers},
    };
    return _render_from_data_section('openqa_get_info.txt.ep', $vars);
}

sub tool_openqa_get_job_info ($tool, $args) {
    my $job_id = $args->{job_id};

    my $schema = _get_schema($tool);
    return $tool->text_result('Job does not exist', 1)
      unless my $job = $schema->resultset('Jobs')->find(int $job_id);
    my @comments = map { $_->extended_hash } $job->search_related(comments => {})->all;

    my $info = $job->to_hash(assets => 1, check_assets => 1, deps => 1, details => 1, parent_group => 1);
    return _render_from_data_section('openqa_get_job_info.txt.ep', {job => $info, comments => \@comments});
}

sub tool_openqa_get_log_file ($tool, $args) {
    my $job_id = $args->{job_id};
    my $file_name = $args->{file_name};

    # Prevent directory traversal attacks
    return $tool->text_result('Invalid file name', 1) unless $file_name =~ /^[\w.\-]+$/;

    # Only text logs for now
    return $tool->text_result('File type not yet supported via MCP', 1) if $file_name !~ /\.txt$/;

    my $schema = _get_schema($tool);
    return $tool->text_result('Job does not exist', 1)
      unless my $job = $schema->resultset('Jobs')->find(int $job_id);

    my $dir = $job->result_dir;
    my $file = path($dir, $file_name);
    return $tool->text_result('Log file does not exist', 1) unless -r $file;

    my $c = _get_controller($tool);
    my $max = $c->app->config->{misc_limits}{mcp_max_result_size};
    return $tool->text_result('File too large to be transmitted via MCP', 1) if -s $file > $max;
    return $tool->text_result($file->slurp);
}

sub _get_controller ($tool) { $tool->context->{controller} }
sub _get_schema ($tool) { _get_controller($tool)->schema }
sub _get_user ($tool) { _get_controller($tool)->stash->{current_user}{user} }

# API controllers are reused instead of reimplementing their logic, so that
# validation, gru tasks, events and audit logging behave like a REST API call
sub _api_call ($tool, %args) {
    my $c = _get_controller($tool);
    my $user = _get_user($tool);
    my $role = $args{role} // 'operator';
    return {error => 'Insufficient role'} if $role eq 'admin' && !$user->is_admin;
    return {error => 'Insufficient role'} if $role eq 'operator' && !$user->is_operator;

    my $params = Mojo::Parameters->new;
    $params->append(@{$args{params} // []});
    my $tx = Mojo::Transaction::HTTP->new(connection => $c->tx->connection);
    my $class = "OpenQA::WebAPI::Controller::API::V1::$args{controller}";
    my $ctrl = $class->new(
        app => $c->app,
        tx => $tx,
        stash => {
            current_user => {user => $user},
            %{$args{captures} // {}},
            'mojo.captures' => {%{$args{captures} // {}}},
            %{$args{stash} // {}}});
    $ctrl->req->method($args{method});
    $ctrl->req->headers->content_type('application/x-www-form-urlencoded');
    $ctrl->req->body($params->to_string);
    my $result;
    try {
        $ctrl->can($args{action})->($ctrl);
        $result = {code => $ctrl->res->code, json => $ctrl->res->json};
    }
    catch ($e) { $result = {error => "$e"} };
    return $result;
}

# MCP arguments are JSON, controllers expect form parameters, so booleans become 1/0
# and lists become comma-separated strings
# restart and duplicate differ only in the controller action and the route
sub _restart_call ($tool, $action, $args) {
    my $job_id = delete $args->{job_id};
    my $settings = delete $args->{settings};
    my $confirmed = _confirm($tool, $args, 'Restart job ' . $job_id . '?');
    return $confirmed if ref $confirmed;
    $args->{set} = [map { "$_=$settings->{$_}" } keys %$settings] if $settings;
    return _call(
        $tool,
        role => 'operator',
        controller => 'Job',
        action => $action,
        method => 'POST',
        path => "/api/v1/jobs/$job_id/$action",
        captures => {jobid => $job_id},
        params => _params($args));
}

sub _confirm ($tool, $args, $question) {
    return 1 if delete $args->{confirm};
    my $responses = $tool->context->input_responses;
    return 1 if $responses && ($responses->{confirm}{action} // '') eq 'accept';
    return $tool->input_required({confirm => {type => 'boolean', title => 'Confirm', description => $question}});
}

sub _params ($args) {
    my @pairs;
    for my $key (sort keys %$args) {
        my $value = $args->{$key};
        next unless defined $value;
        if (ref $value eq 'ARRAY') { push @pairs, $key => $_ for @$value }
        elsif (ref $value) { push @pairs, $key => ($value ? 1 : 0) }
        else { push @pairs, $key => $value }
    }
    return \@pairs;
}

sub _resource_json ($res, %args) {
    my $out = _api_call($res, role => 'user', %args);
    return $res->text_resource($out->{error} // encode_json($out->{json}));
}

sub _structured ($tool, $data) {
    my $max = _get_controller($tool)->app->config->{misc_limits}{mcp_max_result_size};
    return $tool->text_result('Result too large to be transmitted via MCP', 1) if length encode_json($data) > $max;
    return $tool->structured_result($data);
}

sub _call ($tool, %args) {
    my $res = _api_call($tool, %args);
    return $tool->text_result($res->{error}, 1) if $res->{error};
    return $tool->text_result($res->{json}{error} // 'Request failed', 1) if $res->{code} >= 400;
    return _structured($tool, $res->{json});
}

sub _render_from_data_section ($template_name, $vars) {
    my $template = data_section(__PACKAGE__, $template_name);
    return Mojo::Template->new->vars(1)->render($template, $vars);
}

1;
__DATA__
@@ openqa_get_info.txt.ep
Server: <%= $app_name %> (<%= $app_version %>)
Current User: <%= $user_name %> (id: <%= $user_id %>, admin: <%= $is_admin %>, operator: <%= $is_operator %>)
Workers: <%= $workers_total %>
  - online: <%= $workers_total_online %>
  - offline: <%= $workers_offline %>
  - idle: <%= $active_workers %>
  - busy: <%= $busy_workers %>
  - broken: <%= $broken_workers %>

@@ openqa_get_job_info.txt.ep
Job ID:   <%= $job->{id}         // 'Unknown' %>
Name:     <%= $job->{name}       // 'Unknown' %>
Group:   <%= $job->{group}       // 'Unknown' %>
Priority: <%= $job->{priority}   // 'Unknown' %>
State:    <%= $job->{state}      // 'Unknown' %>
Result:   <%= $job->{result}     // 'Unknown' %>
Started:  <%= $job->{t_started}  // 'Never' %>
Finished: <%= $job->{t_finished} // 'Never' %>

Test Results:
% if (@{$job->{testresults}}) {
  % for my $result (@{$job->{testresults}}) {
  - <%= $result->{name} %>: <%= $result->{result} %>
  % }
% }
% else {
  No test results available yet
% }

Test Settings:
% for my $setting (sort keys %{$job->{settings}}) {
  - <%= $setting %>: <%= $job->{settings}{$setting} %>
% }

Available Logs:
% if (@{$job->{logs}}) {
  % for my $log (@{$job->{logs}}) {
  - <%= $log %>
  % }
% }
% else {
  No logs available
% }

Comments:
% if (@$comments) {
  % for my $comment (@$comments) {
  - <%= $comment->{userName} %> (<%= $comment->{created} %>): <%= $comment->{renderedMarkdown} %>
  % }
% }
% else {
  No comments yet
% }
