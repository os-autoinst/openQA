# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::WebAPI::Plugin::IssueReporter::Context;
use Mojo::Base -strict, -signatures;
use Exporter qw(import);

our @EXPORT_OK = qw(get_context get_regression_links);

sub get_context ($c) {
    my $job = $c->stash('job') or return undef;
    my $module = $c->stash('moduleid') // '';
    my $step = $c->stash('stepid');
    my $step_url
      = $step
      ? $c->url_for('step', moduleid => $module, stepid => $step)->to_abs
      : $c->url_for('step')->to_abs;

    return {
        job => $job,
        job_id => $job->id,
        build => $job->BUILD,
        distri => ($job->DISTRI // ''),
        version => ($job->VERSION // ''),
        flavor => ($job->FLAVOR // ''),
        module => $module,
        step_url => "$step_url",
    };
}

# this takes the logic from the external_reporting.html.ep
sub get_regression_links ($c, $job) {
    my $build_link = sub ($j) {
        my $turl = $c->url_for('test', testid => $j->id)->to_abs;
        return '[' . $j->BUILD . "]($turl)";
    };

    my $first_known_bad = $build_link->($job) . ' (current job)';
    my $last_good = '(unknown)';

    for my $prev ($job->_previous_scenario_jobs) {
        if (($prev->result // '') =~ /(passed|softfailed)/) {
            $last_good = $build_link->($prev);
            last;
        }
        $first_known_bad = $build_link->($prev);
    }
    return ($first_known_bad, $last_good);
}

1;
