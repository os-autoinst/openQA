# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::WebAPI::Plugin::IssueReporter::OpenSuseBCIbug;
use Mojo::Base -strict, -signatures;
use Mojo::Template;
use Mojo::Loader qw(data_section);
use Mojo::URL;
use OpenQA::WebAPI::Plugin::IssueReporter::Context qw(get_context get_regression_links);
use OpenQA::WebAPI::Plugin::IssueReporter::OpenSuseBugzillaUtils qw(get_bugzilla_url);

sub actions ($c) {
    my $ctx = get_context($c) or return [];
    my $job = $ctx->{job};
    my $raw_distri = $job->DISTRI // '';
    my $bz_product = 'SUSE Linux Base Container Images';
    my $bz_url = get_bugzilla_url($raw_distri);
    my (undef, $last_good) = get_regression_links($c, $job);
    my $latest = $c->url_for('latest')->query($job->scenario_hash)->to_abs;
    my ($build, $image) = split /_/, $ctx->{build}, 2;

    my @wanted_keys = qw(BCI_TEST_ENVS CONTAINER_IMAGE_TO_TEST HDD_1 CONTAINER_RUNTIMES);
    my %is_wanted = map { $_ => 1 } @wanted_keys;
    my %settings;
    for my $setting ($job->settings->all) {
        if ($is_wanted{$setting->key}) {
            $settings{$setting->key} = $setting->value;
        }
    }

    my $bci_bug = _render(
        'bci_bug.txt.ep',
        {
            step_url => $ctx->{step_url},
            last_good => $last_good,
            latest => "$latest",
            image => $settings{CONTAINER_IMAGE_TO_TEST},
            host_os => $settings{HDD_1},
            bci_tests => $settings{BCI_TEST_ENVS},
            cri => $settings{CONTAINER_RUNTIMES}});

    my $url = Mojo::URL->new($bz_url)->query(
        {
            short_desc => "[QE][Build $build] $image fails",
            comment => $bci_bug,
            product => $bz_product,
            bug_file_loc => $ctx->{step_url},
            cf_foundby => 'openQA',
        });

    return [
        {
            id => 'bci_bugs',
            label => 'Report BCI image bug',
            icon => 'fa-layer-group',
            url => "$url",
        }];
}

sub _render ($name, $vars) {
    my $tmpl = data_section(__PACKAGE__, $name);
    return Mojo::Template->new(vars => 1)->render($tmpl, $vars);
}

1;

__DATA__
@@ bci_bug.txt.ep
## Failed test

<%= $step_url %>

## Test environment

Container image: <%= $image %>
HostOS: <%= $host_os %>
BCI tests: <%= $bci_tests %>
Container runtime: <%= $cri %>

## Useful links

Last good: <%= $last_good %> (or more recent)
The latest result in this scenario: <%= $latest %>
