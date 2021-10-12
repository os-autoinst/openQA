# Copyright 2020 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::WebAPI::Controller::API::V1::Search;
use Mojo::Base 'Mojolicious::Controller';

use OpenQA::Utils;
use Mojo::File 'path';
use IPC::Run;

=pod

=head1 NAME

OpenQA::WebAPI::Controller::API::V1::Search

=head1 SYNOPSIS

  use OpenQA::WebAPI::Controller::API::V1::Search;

=head1 DESCRIPTION

Implements API methods to search (for) tests.

=head1 METHODS

=cut

# Helper methods

=over 4

=item query()

Renders an array of search results.

=over 8

=item q

One or multiple keywords, treated as literal strings.

=back

The response will have these fields:

=over

=item B<data>: the array of search results, with B<occurrence> and B<contents> in case of a fulltext match

=item B<error>: an array of errors if validation or retrieving results failed

=back

The B<data> and B<error> fields are mutually exclusive.

=back

=cut

sub _search_perl_modules {
    my ($self, $keywords, $cap) = @_;

    my @results;
    my $distris = path(OpenQA::Utils::testcasedir);
    for my $distri ($distris->list({dir => 1})->map('realpath')->uniq()->each) {
        # Skip files residing in the test root
        next unless -d $distri;

        # Test module filenames
        for my $filename (
            $distri->list_tree()->head($cap)->map('to_rel', $distris)->grep(qr/.*\Q$keywords\E.*\.p[my]$/)->each)
        {
            push(@results, {occurrence => $filename});
            $cap--;
        }
        last if $cap < 1;

        # Contents of test modules
        my @cmd = ('git', '-C', $distri, 'grep', '--line-number', '--no-index', '-F', $keywords, '--', '*.p[my]');
        my $stdout;
        my $stderr;
        IPC::Run::run(\@cmd, \undef, \$stdout, \$stderr);
        return $self->render(json => {error => "Grep failed: $stderr"}, status => 400) if $stderr;

        my $basename = $distri->basename;
        my $last_filename = '';
        my @lines = split("\n", $stdout);
        foreach my $match (@lines) {
            next unless length $match;
            my ($filename, $linenr, $contents) = split(':', $match, 3);
            # Prefix each line with a 5 digit-padded number
            $contents = sprintf("%5d ", $linenr) . $contents;
            # Merge lines occurring in the same file
            if ($filename eq $last_filename) {
                $results[-1]->{contents} .= "\n$contents";
                next;
            }
            $last_filename = $filename;
            push(@results, {occurrence => "$basename/$filename", contents => $contents});
            # For the purposes of the limit, all lines in the same file count as one
            $cap--;
            last if $cap < 1;
        }
    }
    return \@results;
}

sub _search_job_modules {
    my ($self, $keywords, $limit) = @_;

    my @results;
    my $last_job = -1;
    my $like = {like => "%${keywords}%"};
    # Get job modules for distinct jobs (by the columns comprising the computed name)
    my $job_modules = $self->schema->resultset('JobModules')->search(
        {-or => {name => $like}},
        {
            join => 'job',
            group_by =>
              ['me.id', 'job.DISTRI', 'job.VERSION', 'job.FLAVOR', 'job.TEST', 'job.ARCH', 'job.MACHINE', 'job.id'],
            prefetch => [qw(job)],
            select => [qw(me.id me.script me.job_id job.DISTRI job.VERSION job.FLAVOR job.ARCH job.BUILD job.TEST)],
            order_by => {-desc => 'job_id'}})->slice(0, $limit);
    while (my $job_module = $job_modules->next) {
        my $contents = $job_module->script;
        if ($job_module->job_id == $last_job) {
            $results[-1]->{contents} .= "\n$contents";
            next;
        }
        $last_job = $job_module->job_id;
        push(@results, {occurrence => $job_module->job->name, contents => $contents});
    }
    return \@results;
}

sub _search_job_templates {
    my ($self, $keywords, $limit) = @_;

    my @results;
    my $last_group = -1;
    my $like = {like => "%${keywords}%"};

    # Take into account names of test suites in cases where the job template itself has no name or description,
    # but is based off of a test suite
    my $templates = $self->schema->resultset('JobTemplates')->search(
        {-or => ['me.name' => $like, 'me.description' => $like, 'test_suite.name' => $like]},
        {
            join => 'test_suite',
            order_by => {-desc => 'group_id'}})->slice(0, $limit);
    while (my $template = $templates->next) {
        my $template_name = $template->name ? $template->name : $template->test_suite->name;
        my $contents = $template_name . "\n" . $template->description;

        if ($template->group->id == $last_group) {
            $results[-1]->{contents} .= "\n$contents";
            next;
        }
        $last_group = $template->group->id;
        push(@results, {occurrence => $template->group->name, contents => $contents});
    }
    return \@results;
}

sub query {
    my ($self) = @_;

    my $validation = $self->validation;
    $validation->required('q');
    return $self->reply->validation_error({format => 'json'}) if $validation->has_error;

    # Allow n queries per minute, per user (if logged in)
    my $lockname = 'webui_query_rate_limit';
    if (my $user = $self->current_user) { $lockname .= $user->username }
    return $self->render(json => {error => 'Rate limit exceeded'}, status => 400)
      unless $self->app->minion->lock($lockname, 60, {limit => $self->app->config->{'rate_limits'}->{'search'}});

    my $cap = $self->app->config->{'global'}->{'search_results_limit'};
    my @results;
    my $keywords = $validation->param('q');

    my $perl_module_results = $self->_search_perl_modules($keywords, $cap);
    $cap -= scalar @{$perl_module_results};
    push @results, @{$perl_module_results};
    return $self->render(json => {data => \@results}) unless $cap > 0;

    my $job_module_results = $self->_search_job_modules($keywords, $cap);
    $cap -= scalar @{$job_module_results};
    push @results, @{$job_module_results};
    return $self->render(json => {data => \@results}) unless $cap > 0;

    push @results, @{$self->_search_job_templates($keywords, $cap)};

    $self->render(json => {data => \@results});
}

1;
