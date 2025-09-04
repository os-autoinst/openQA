# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::WebAPI::Plugin::MCP;
use Mojo::Base 'Mojolicious::Plugin', -signatures;

use MCP::Server;
use Mojo::Template;
use Mojo::Loader qw(data_section);
use Mojo::File qw(path);

sub register ($self, $app, $config) {
    my $mcp = MCP::Server->new;
    $mcp->name('openQA');
    $mcp->version('1.0.0');

    $mcp->tool(
        name => 'openqa_get_info',
        description => 'Get information about the openQA server, connected workers and the current user',
        code => \&tool_openqa_get_info
    );

    $mcp->tool(
        name => 'openqa_get_job_info',
        description => 'Get information about a specific openQA job',
        input_schema => {
            type => 'object',
            properties => {job_id => {type => 'integer', minimum => 1}},
            required => ['job_id'],
        },
        code => \&tool_openqa_get_job_info
    );

    $mcp->tool(
        name => 'openqa_get_log_file',
        description => 'Get the content of a specific log file for an openQA job',
        input_schema => {
            type => 'object',
            properties => {
                job_id => {type => 'integer', minimum => 1},
                file_name => {type => 'string', minLength => 1}
            },
            required => ['job_id', 'file_name'],
        },
        code => \&tool_openqa_get_log_file
    );

    my $mcp_auth = $app->routes->under('/')->to('Auth#auth')->name('mcp_ensure_user');
    $mcp_auth->any('/experimental/mcp' => $mcp->to_action)->name('mcp');
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
      unless my $job = $schema->resultset('Jobs')->find(int($job_id));
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
      unless my $job = $schema->resultset('Jobs')->find(int($job_id));

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
