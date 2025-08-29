# Copyright 2025 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::WebAPI::Plugin::MCP;
use Mojo::Base 'Mojolicious::Plugin', -signatures;

use MCP::Server;
use Mojo::Template;
use Mojo::Loader qw(data_section);

sub register ($self, $app, $config) {
    my $mcp = MCP::Server->new;
    $mcp->name('openQA');
    $mcp->version('1.0.0');

    $mcp->tool(
        name => 'openqa_user',
        description => 'Get information about the current openQA user',
        code => \&tool_openqa_user
    );

    $mcp->tool(
        name => 'openqa_job_info',
        description => 'Get information about a pecific openQA job',
        input_schema => {
            type => 'object',
            properties => {job_id => {type => 'integer', minimum => 1}},
            required => ['job_id'],
        },
        code => \&tool_openqa_job_info
    );

    my $mcp_auth = $app->routes->under('/')->to('Auth#auth')->name('mcp_ensure_user');
    $mcp_auth->any('/experimental/mcp' => $mcp->to_action)->name('mcp');
}

sub tool_openqa_user ($tool, $args) {
    my $user = _get_user($tool);
    my $vars = {
        name => $user->name,
        id => $user->id,
        is_admin => $user->is_admin ? 'yes' : 'no',
        is_operator => $user->is_operator ? 'yes' : 'no'
    };
    return _render_from_data_section('openqa_user.txt.ep', $vars);
}

sub tool_openqa_job_info ($tool, $args) {
    my $job_id = $args->{job_id};

    my $schema = _get_schema($tool);
    return $tool->text_result('Job does not exist', 1)
      unless my $job = $schema->resultset('Jobs')->find(int($job_id));
    my @comments = map { $_->extended_hash } $job->search_related(comments => {})->all;

    my $info = $job->to_hash(assets => 1, check_assets => 1, deps => 1, details => 1, parent_group => 1);
    return _render_from_data_section('openqa_job_info.txt.ep', {job => $info, comments => \@comments});
}

sub _get_schema ($tool) {
    return $tool->context->{controller}->schema;
}

sub _get_user ($tool) {
    return $tool->context->{controller}->stash->{current_user}{user};
}

sub _render_from_data_section ($template_name, $vars) {
    my $template = data_section(__PACKAGE__, $template_name);
    return Mojo::Template->new->vars(1)->render($template, $vars);
}

1;
__DATA__
@@ openqa_user.txt.ep
name: <%= $name %>, id: <%= $id %>, admin: <%= $is_admin %>, operator: <%= $is_operator %>

@@ openqa_job_info.txt.ep
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
  - No test results available yet
% }

Test Settings:
% for my $setting (sort keys %{$job->{settings}}) {
  - <%= $setting %>: <%= $job->{settings}{$setting} %>
% }

Comments:
% if (@$comments) {
  % for my $comment (@$comments) {
  - <%= $comment->{userName} %> (<%= $comment->{created} %>): <%= $comment->{renderedMarkdown} %>
  % }
% }
% else {
  - No comments yet
% }
