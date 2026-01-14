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
            return [
                @{OpenQA::WebAPI::Plugin::IssueReporter::OpenSuseGenericBug::actions($c)},
                @{OpenQA::WebAPI::Plugin::IssueReporter::OpenSuseKernelBug::actions($c)},
                @{OpenQA::WebAPI::Plugin::IssueReporter::OpenSuseProgressIssue::actions($c)},
            ];
        });
}

1;
