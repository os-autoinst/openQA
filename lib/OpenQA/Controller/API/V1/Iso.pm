# Copyright (C) 2014 SUSE Linux Products GmbH
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
# with this program; if not, write to the Free Software Foundation, Inc.,
# 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.

package OpenQA::Controller::API::V1::Iso;
use Mojo::Base 'Mojolicious::Controller';
use OpenQA::Utils;
use OpenQA::Scheduler ();
use Try::Tiny;

# return settings key for given job settings
sub _settings_key {
    my ($settings) = @_;
    return $settings->{TEST} . ':' . $settings->{MACHINE};

}

# parse dependency variable in format like "suite1,suite2,suite3"
# and return settings key for each entry
# TODO: allow inter-machine dependency
sub _parse_dep_variable {
    my ($value, $settings) = @_;

    return unless defined $value;

    my @after = split(/\s*,\s*/, $value);

    return map { $_ . ':' . $settings->{MACHINE} } @after;
}

# sort the job list so that children are put after parents
sub _sort_dep {
    my ($self, $list) = @_;

    my %done;
    my %count;
    my @out;

    for my $job (@$list) {
        $count{_settings_key($job)} //= 0;
        $count{_settings_key($job)}++;
    }


    my $added;
    do {
        $added = 0;
        for my $job (@$list) {
            next if $done{$job};
            my @after;
            push @after, _parse_dep_variable($job->{START_AFTER_TEST}, $job);
            push @after, _parse_dep_variable($job->{PARALLEL_WITH}, $job);

            my $c = 0; # number of parens that must go to @out before this job
            foreach my $a (@after) {
                $c += $count{$a} if defined $count{$a};
            }

            if ($c == 0) { # no parents, we can do this job
                push @out, $job;
                $done{$job} = 1;
                $count{_settings_key($job)}--;
                $added = 1;
            }
        }
    } while ($added);

    #cycles, broken dep, put at the end of the list
    for my $job (@$list) {
        next if $done{$job};
        push @out, $job;
    }

    return \@out;
}

sub _generate_jobs {
    my ($self, %args) = @_;

    my $ret = [];

    my @products = $self->db->resultset('Products')->search(
        {
            distri => lc($args{DISTRI}),
            version => $args{VERSION},
            flavor => $args{FLAVOR},
            arch => $args{ARCH},
        }
    );

    unless (@products) {
        $self->app->log->debug("no products found, retrying version wildcard");
        @products = $self->db->resultset('Products')->search(
            {
                distri => lc($args{DISTRI}),
                # TODO: add conversion to future migration script?
                -or => [
                    version => '',
                    version => '*',
                ],
                flavor => $args{FLAVOR},
                arch => $args{ARCH},
            }
        );
    }

    if (@products) {
        $self->app->log->debug("products: ". join(',', map { $_->name } @products));
    }
    else {
        $self->app->log->error("no products found for ".join('-', map { $args{$_} } qw/DISTRI VERSION FLAVOR ARCH/));
    }

    for my $product (@products) {
        my @templates = $product->job_templates;
        unless (@templates) {
            $self->app->log->error("no templates found for ".join('-', map { $args{$_} } qw/DISTRI VERSION FLAVOR ARCH/));
        }
        for my $job_template (@templates) {
            my %settings = map { $_->key => $_->value } $product->settings;

            my %tmp_settings = map { $_->key => $_->value } $job_template->machine->settings;
            @settings{keys %tmp_settings} = values %tmp_settings;

            %tmp_settings = map { $_->key => $_->value } $job_template->test_suite->settings;
            @settings{keys %tmp_settings} = values %tmp_settings;
            $settings{TEST} = $job_template->test_suite->name;
            $settings{MACHINE} = $job_template->machine->name;

            next if $args{TEST} && $args{TEST} ne $settings{TEST};
            next if $args{MACHINE} && $args{MACHINE} ne $settings{MACHINE};

            for (keys  %args) {
                $settings{uc $_} = $args{$_};
            }
            # Makes sure tha the DISTRI is lowercase
            $settings{DISTRI} = lc($settings{DISTRI});

            $settings{PRIO} = $job_template->test_suite->prio;

            push @$ret, \%settings;
        }
    }

    return $self->_sort_dep($ret);
}


sub create {
    my $self = shift;

    my $validation = $self->validation;
    $validation->required('DISTRI');
    $validation->required('VERSION');
    $validation->required('FLAVOR');
    $validation->required('ARCH');
    if ($validation->has_error) {
        my $error = "Error: missing parameters:";
        for my $k (qw/DISTRI VERSION FLAVOR ARCH/) {
            $self->app->log->debug(@{$validation->error($k)}) if $validation->has_error($k);
            $error .= ' '.$k if $validation->has_error($k);
        }
        $self->res->message($error);
        return $self->rendered(400);
    }

    my $params = $self->req->params->to_hash;
    # job_create expects upper case keys
    my %up_params = map { uc $_ => $params->{$_} } keys %$params;

    my $jobs = $self->_generate_jobs(%up_params);

    # XXX: take some attributes from the first job to guess what old jobs to
    # cancel. We should have distri object that decides which attributes are
    # relevant here.
    if ($jobs && $jobs->[0] && $jobs->[0]->{BUILD}) {
        my %cond;
        for my $k (qw/DISTRI VERSION FLAVOR ARCH/) {
            next unless $jobs->[0]->{$k};
            $cond{$k} = $jobs->[0]->{$k};
        }
        if (%cond) {
            OpenQA::Scheduler::job_cancel(\%cond, 1); # have new build jobs instead
        }
    }

    my $cnt = 0;
    my @ids;

    # the jobs are now sorted parents first
    # remember ids of created parents and pass them to _START_AFTER_JOBS/_PARALLEL_JOBS of children
    my %testsuite_ids; # key: "suite:machine", value: array of job ids

    for my $settings (@{$jobs||[]}) {
        my $prio = $settings->{PRIO};
        delete $settings->{PRIO};

        # convert testsuite names in START_AFTER_TEST/PARALLEL_WITH to job ids
        for my $after (_parse_dep_variable($settings->{START_AFTER_TEST}, $settings)) {
            if (defined $testsuite_ids{$after}) {
                $settings->{_START_AFTER_JOBS} //= [];
                push @{$settings->{_START_AFTER_JOBS}}, @{$testsuite_ids{$after}};
            }
            else {
                $self->app->log->error("START_AFTER_TEST=" . $after . " not found, maybe a typo or a dependency cycle");
            }
        }
        for my $after (_parse_dep_variable($settings->{PARALLEL_WITH}, $settings)) {
            if (defined $testsuite_ids{$after}) {
                $settings->{_PARALLEL_JOBS} //= [];
                push @{$settings->{_PARALLEL_JOBS}}, @{$testsuite_ids{$after}};
            }
            else {
                $self->app->log->error("PARALLEL_WITH=" . $after . " not found, maybe a typo or a dependency cycle");
            }
        }
        # create a new job with these parameters and count if successful, do not send job notifies yet
        my $id;
        try {
            $id = OpenQA::Scheduler::job_create($settings, 1);
        }
        catch {
            chomp;
            $self->app->log->error("job_create: $_");
        };
        if ($id) {
            $cnt++;
            push @ids, $id;

            $testsuite_ids{_settings_key($settings)} //= [];
            push @{$testsuite_ids{_settings_key($settings)}}, $id;

            # change prio only if other than defalt prio
            if( $prio && $prio != 50 ) {
                OpenQA::Scheduler::job_set_prio(jobid => $id, prio => $prio);
            }
        }
    }
    #notify workers new jobs are available
    OpenQA::Scheduler::job_notify_workers();
    $self->app->log->debug("created $cnt jobs");
    $self->render(json => {count => $cnt, ids => \@ids });
}

sub destroy {
    my $self = shift;
    my $iso = $self->stash('name');

    my $res = OpenQA::Scheduler::job_delete($iso);
    $self->render(json => {count => $res});
}

sub cancel {
    my $self = shift;
    my $iso = $self->stash('name');

    my $res = OpenQA::Scheduler::job_cancel($iso);
    $self->render(json => {result => $res});
}

1;
# vim: set sw=4 et:
