# Copyright (C) 2020 SUSE LLC
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

sub query {
    my ($self) = @_;

    my $validation = $self->validation;
    $validation->required('q');
    return $self->reply->validation_error({format => 'json'}) if $validation->has_error;

    # Allow n queries per minute, per user (if logged in)
    my $lockname = 'webui_query_rate_limit';
    if (my $user = $self->current_user) { $lockname .= $user }
    return $self->render(json => {error => 'Rate limit exceeded'}, status => 400)
      unless $self->app->minion->lock($lockname, 60, {limit => $self->app->config->{'rate_limits'}->{'search'}});

    my $cap = $self->app->config->{'global'}->{'search_results_limit'};
    my @results;
    my $keywords = $validation->param('q');
    my $distris  = path(OpenQA::Utils::testcasedir);
    for my $distri ($distris->list({dir => 1})->each) {
        # Skip files residing in the test root
        next unless -d $distri;

        # Perl module filenames
        for my $filename (
            $distri->list_tree()->head($cap)->map('to_rel', $distris)->grep(qr/.*\Q$keywords\E.*\.pm$/)->each)
        {
            push(@results, {occurrence => $filename});
        }
        $cap -= scalar @results;
        last if $cap < 1;

        # Contents of Perl modules
        my @cmd = ('git', '-C', $distri, 'grep', '--no-index', '-F', $keywords, '--', '*.pm');
        my $stdout;
        my $stderr;
        IPC::Run::run(\@cmd, \undef, \$stdout, \$stderr);
        return $self->render(json => {error => "Grep failed: $stderr"}, status => 400) if $stderr;

        my $basename = $distri->basename;
        my @lines    = split("\n", $stdout);
        splice @lines, $cap;
        foreach my $match (@lines) {
            next unless length $match;
            my ($filename, $occurrence) = split(':', $match);
            push(@results, {occurrence => "$basename/$filename", contents => $occurrence});
        }
        $cap -= scalar @results;
        last if $cap < 1;

        # Job templates
        my $last_group = undef;
        my $like       = {like => "%${keywords}%"};
        my $templates  = $self->schema->resultset('JobTemplates')
          ->search({-or => {name => $like, description => $like}}, {limit => $cap});
        while (my $template = $templates->next) {
            my $contents = $template->name . "\n" . $template->description;
            if ($template->group->id == $last_group) {
                $results[-1]->{contents} .= "\n$contents";
                next;
            }
            $last_group = $template->group->id;
            push(@results, {occurrence => $template->group->name, contents => $contents});
        }
        $cap -= scalar @results;
        last if $cap < 1;
    }

    $self->render(json => {data => \@results});
}

1;
