# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::WebAPI::Plugin::IssueReporter::OpenSuseProgressIssue;
use Mojo::Base -strict, -signatures;
use Mojo::Template;
use Mojo::Loader qw(data_section);
use Mojo::URL;
use OpenQA::WebAPI::Plugin::IssueReporter::Context qw(get_context get_regression_links);

# below constants are taken directly from the external_reporting.html.ep
# kept here as such since this single issue tracker is used with single category_id
use constant PROGRESS_URL => 'https://progress.opensuse.org/projects/openqatests/issues/new';
use constant DEFAULT_CATEGORY_ID => 152;

sub actions ($c) {
    my $ctx = get_context($c) or return [];

    my $job = $ctx->{job};
    my $scenario = $job->scenario_name // '';
    my $scenario_description = $job->scenario_description // '';
    my ($first_known_bad, $last_good) = get_regression_links($c, $job);
    my $latest = $c->url_for('latest')->query($job->scenario_hash)->to_abs;

    my $subject = "test fails in $ctx->{module}";
    my $body = _render(
        'progress_issue.txt.ep',
        {
            scenario => $scenario,
            module => $ctx->{module},
            step_url => $ctx->{step_url},
            scenario_description => $scenario_description,
            first_known_bad => $first_known_bad,
            last_good => $last_good,
            latest => "$latest",
        });

    my $url = Mojo::URL->new(PROGRESS_URL)->query(
        {
            'issue[subject]' => $subject,
            'issue[description]' => $body,
            'issue[category_id]' => DEFAULT_CATEGORY_ID,
        });

    return [
        {
            id => 'progress_issue',
            label => 'Report test issue',
            icon => 'fa-bolt',
            url => "$url",
        }];
}

sub _render ($name, $vars) {
    my $tmpl = data_section(__PACKAGE__, $name);
    return Mojo::Template->new(vars => 1)->render($tmpl, $vars);
}

1;

__DATA__
@@ progress_issue.txt.ep
## Observation

openQA test in scenario <%= $scenario %> fails in
[<%= $module %>](<%= $step_url %>)

## Test suite description
<%= $scenario_description %>

## Reproducible

Fails since (at least) Build <%= $first_known_bad %>

## Expected result

Last good: <%= $last_good %> (or more recent)

## Further details

Always latest result in this scenario: [latest](<%= $latest %>)
