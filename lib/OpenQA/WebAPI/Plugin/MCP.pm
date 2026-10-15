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

sub register ($self, $app, $config) {
    my $mode = $config->{mode} // 'read-only';
    my $mcp = MCP::Server->new;
    $mcp->name('openQA');
    $mcp->version('1.0.0');

    $mcp->tool(
        name => 'openqa_get_info',
        title => 'Get openQA Server Info',
        description => 'Get information about the openQA server, connected workers and the current user',
        input_schema => {type => 'object', properties => {}, additionalProperties => \0},
        annotations => {
            title => 'Get openQA Server Info',
            readOnlyHint => \1,
            destructiveHint => \0,
            idempotentHint => \1,
            openWorldHint => \0,
        },
        code => \&tool_openqa_get_info
    );

    $mcp->tool(
        name => 'openqa_get_job_info',
        title => 'Get openQA Job Details',
        description => 'Get any information about a specific openQA job, like logs, scheduling etc.',
        input_schema => {
            type => 'object',
            properties =>
              {job_id => {type => 'integer', minimum => 1, description => 'The job ID of any openQA test suite.'}},
            required => ['job_id'],
            additionalProperties => \0,
        },
        annotations => {
            title => 'Get openQA Job Details',
            readOnlyHint => \1,
            destructiveHint => \0,
            idempotentHint => \1,
            openWorldHint => \0,
        },
        code => \&tool_openqa_get_job_info
    );

    $mcp->tool(
        name => 'openqa_get_log_file',
        title => 'Get openQA Job Log File',
        description => 'Get the content of a specific log file for an openQA job',
        input_schema => {
            type => 'object',
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
            additionalProperties => \0,
        },
        annotations => {
            title => 'Get openQA Job Log File',
            readOnlyHint => \1,
            destructiveHint => \0,
            idempotentHint => \1,
            openWorldHint => \0,
        },
        code => \&tool_openqa_get_log_file
    );

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
    $params->append($_, $args{params}{$_}) for keys %{$args{params}};
    my $tx = Mojo::Transaction::HTTP->new(connection => $c->tx->connection);
    my $class = "OpenQA::WebAPI::Controller::API::V1::$args{controller}";
    my $ctrl = $class->new(
        app => $c->app,
        tx => $tx,
        stash => {current_user => {user => $user}, %{$args{stash}}});
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
