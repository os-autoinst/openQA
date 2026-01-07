# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::WebAPI::Plugin::IssueReporter::OpenSuseIssueReporter;
use Mojo::Base 'Mojolicious::Plugin', -signatures;

use OpenQA::WebAPI::Plugin::IssueReporter::OpenSuseKernelBug;
use OpenQA::WebAPI::Plugin::IssueReporter::OpenSuseGenericBug;
use OpenQA::WebAPI::Plugin::IssueReporter::OpenSuseProgressIssue;

sub register ($self, $app, $config) {
    $app->helper(
        report_external_issue => sub ($c) {
            my @actions;

            push @actions, @{OpenQA::WebAPI::Plugin::IssueReporter::OpenSuseGenericBug::actions($c)};
            push @actions, @{OpenQA::WebAPI::Plugin::IssueReporter::OpenSuseKernelBug::actions($c)};
            push @actions, @{OpenQA::WebAPI::Plugin::IssueReporter::OpenSuseProgressIssue::actions($c)};

            return \@actions;
        });
}

1;
