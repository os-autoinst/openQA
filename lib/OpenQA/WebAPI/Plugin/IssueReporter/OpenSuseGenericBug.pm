# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::WebAPI::Plugin::IssueReporter::OpenSuseGenericBug;
use Mojo::Base -strict, -signatures;
use Mojo::Template;
use Mojo::Loader qw(data_section);
use Mojo::URL;
use OpenQA::WebAPI::Plugin::IssueReporter::Context qw(get_context get_regression_links);
use OpenQA::WebAPI::Plugin::IssueReporter::OpenSuseBugzillaUtils
  qw(get_bugzilla_url get_bugzilla_distri_name get_bugzilla_product_name);

sub actions ($c) {
    my $ctx = get_context($c) or return [];
    my $job = $ctx->{job};
    my $raw_distri = $job->DISTRI // '';
    my $distri_name = get_bugzilla_distri_name($raw_distri);
    my $bugzilla_product = get_bugzilla_product_name($job, $raw_distri, \$distri_name);
    my $bugzilla_url = get_bugzilla_url($raw_distri);
    my $scenario = $job->scenario_name // '';
    my $scenario_description = $job->scenario_description // '';
    my ($first_known_bad, $last_good) = get_regression_links($c, $job);
    my $latest = $c->url_for('latest')->query($job->scenario_hash)->to_abs;

    my $body = _render(
        'generic_bug.txt.ep',
        {
            scenario => $scenario,
            scenario_description => $scenario_description,
            module => $ctx->{module},
            step_url => $ctx->{step_url},
            first_known_bad => $first_known_bad,
            last_good => $last_good,
            latest => "$latest",
        });

    my $url = Mojo::URL->new($bugzilla_url)->query(
        {
            short_desc => "[Build $ctx->{build}] openQA test fails in $ctx->{module}",
            comment => $body,
            product => "$distri_name $bugzilla_product",
            bug_file_loc => $ctx->{step_url},
            cf_foundby => 'openQA',
            cf_blocker => 'Yes',
        });

    return [
        {
            id => 'generic_bugzilla',
            label => 'Report product bug',
            icon => 'fa-bug',
            url => "$url",
        }];
}

sub _render ($name, $vars) {
    my $tmpl = data_section(__PACKAGE__, $name);
    return Mojo::Template->new(vars => 1)->render($tmpl, $vars);
}

1;

__DATA__
@@ generic_bug.txt.ep
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
