#!/usr/bin/env perl

# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Mojo::Base -signatures;
use DBIx::Class::DeploymentHandler;

sub ($schema, @args) {
    # init default_keep_*jobs_in_days with default_keep_*results_in_days so existing groups are treated as before
    for my $group ($schema->resultset('JobGroupParents')->search({})->all) {
        if (defined(my $retention = $group->get_column('default_keep_results_in_days'))) {
            $group->update({default_keep_jobs_in_days => $retention});
        }
        if (defined(my $imp_retention = $group->get_column('default_keep_important_results_in_days'))) {
            $group->update({default_keep_important_jobs_in_days => $imp_retention});
        }
    }

    # init keep_*jobs_in_days with keep_*results_in_days so existing groups are treated as before
    for my $group ($schema->resultset('JobGroups')->search({})->all) {
        if (defined(my $retention = $group->get_column('keep_results_in_days'))) {
            $group->update({keep_jobs_in_days => $retention});
        }
        if (defined(my $imp_retention = $group->get_column('keep_important_results_in_days'))) {
            $group->update({keep_important_jobs_in_days => $imp_retention});
        }
    }
}
