# Copyright 2022 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Script::CloneJobSUSE;
use Mojo::Base -strict, -signatures;
use Data::Dump 'pp';
use Exporter 'import';

our @EXPORT = qw(detect_maintenance_update);

sub collect_incident_repos ($url_handler, $settings) {
    if (my $repo = $settings->{INCIDENT_REPO}) {
        return verify_incident_repos($url_handler, $repo);
    }
    my @urls;
    if (my $addons = $settings->{SCC_ADDONS}) {
        foreach my $SCC_ADDON (split(/,/, $addons)) {
            if (my $repo = $settings->{uc($SCC_ADDON) . '_TEST_REPOS'}) {
                my $incident_urls = verify_incident_repos($url_handler, $repo);
                push @urls, @$incident_urls;
            }
        }
    }
    return \@urls;
}

sub verify_incident_repos ($url_handler, $incident_repos) {
    my @incident_urls;
    my $ua = $url_handler->{ua};
    foreach my $incident (split(/,/, $incident_repos)) {
        push @incident_urls, $incident unless $ua->get($incident)->is_success;
    }
    return \@incident_urls;
}

sub detect_maintenance_update ($jobid, $url_handler, $settings) {
    return undef if $settings->{SKIP_MAINTENANCE_UPDATES};
    my $urls = collect_incident_repos($url_handler, $settings);
    die "Current job $jobid will fail, because the repositories for the below updates are unavailable\n" . pp($urls)
      if @$urls;
}

1;
