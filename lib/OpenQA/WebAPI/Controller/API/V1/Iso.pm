# Copyright (C) 2016 SUSE LLC
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

package OpenQA::WebAPI::Controller::API::V1::Iso;
use Mojo::Base 'Mojolicious::Controller';
use Mojo::Util 'url_unescape';
use File::Spec::Functions qw/catfile catdir/;

use OpenQA::Utils;
use OpenQA::IPC;
use Try::Tiny;
use DBIx::Class::Timestamps qw/now/;

use Carp;

use OpenQA::Scheduler::Scheduler 'job_notify_workers';

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
    my ($list) = @_;

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
            push @after, _parse_dep_variable($job->{PARALLEL_WITH},    $job);

            my $c = 0;    # number of parens that must go to @out before this job
            foreach my $a (@after) {
                $c += $count{$a} if defined $count{$a};
            }

            if ($c == 0) {    # no parents, we can do this job
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
    my ($self, $args) = @_;

    my $ret = [];

    my @products = $self->app->db->resultset('Products')->search(
        {
            distri  => lc($args->{DISTRI}),
            version => $args->{VERSION},
            flavor  => $args->{FLAVOR},
            arch    => $args->{ARCH},
        });

    unless (@products) {
        warn "no products found, retrying version wildcard";
        @products = $self->app->db->resultset('Products')->search(
            {
                distri  => lc($args->{DISTRI}),
                version => '*',
                flavor  => $args->{FLAVOR},
                arch    => $args->{ARCH},
            });
    }

    if (!@products) {
        carp "no products found for " . join('-', map { $args->{$_} } qw/DISTRI VERSION FLAVOR ARCH/);
    }

    my %wanted;    # jobs specified by $args->{TEST} or $args->{MACHINE} or their parents

    for my $product (@products) {
        my @templates = $product->job_templates;
        unless (@templates) {
            carp "no templates found for " . join('-', map { $args->{$_} } qw/DISTRI VERSION FLAVOR ARCH/);
        }
        for my $job_template (@templates) {
            my %settings = map { $_->key => $_->value } $product->settings;

            # we need to merge worker classes of all 3
            my @classes;
            if (my $class = delete $settings{WORKER_CLASS}) {
                push @classes, $class;
            }

            my %tmp_settings = map { $_->key => $_->value } $job_template->machine->settings;
            if (my $class = delete $tmp_settings{WORKER_CLASS}) {
                push @classes, $class;
            }
            @settings{keys %tmp_settings} = values %tmp_settings;

            %tmp_settings = map { $_->key => $_->value } $job_template->test_suite->settings;
            if (my $class = delete $tmp_settings{WORKER_CLASS}) {
                push @classes, $class;
            }
            @settings{keys %tmp_settings} = values %tmp_settings;
            $settings{TEST}               = $job_template->test_suite->name;
            $settings{MACHINE}            = $job_template->machine->name;
            $settings{BACKEND}            = $job_template->machine->backend;
            $settings{WORKER_CLASS} = join(',', sort(@classes));

            for (keys %$args) {
                next if $_ eq 'TEST' || $_ eq 'MACHINE';
                $settings{uc $_} = $args->{$_};
            }
            # Makes sure tha the DISTRI is lowercase
            $settings{DISTRI} = lc($settings{DISTRI});

            $settings{PRIO}     = $job_template->prio;
            $settings{GROUP_ID} = $job_template->group_id;

            # variable expansion
            # replace %NAME% with $settings{NAME}
            my $expanded;
            do {
                $expanded = 0;
                for my $var (keys %settings) {
                    if ((my $val = $settings{$var}) =~ /(%\w+%)/) {
                        my $replace_var = $1;
                        $replace_var =~ s/^%(\w+)%$/$1/;
                        my $replace_val = $settings{$replace_var};
                        next unless defined $replace_val;
                        $replace_val = '' if $replace_var eq $var;    #stop infinite recursion
                        $val =~ s/%${replace_var}%/$replace_val/g;
                        $settings{$var} = $val;
                        $expanded = 1;
                    }
                }
            } while ($expanded);

            if (   (!$args->{TEST} || $args->{TEST} eq $settings{TEST})
                && (!$args->{MACHINE} || $args->{MACHINE} eq $settings{MACHINE}))
            {
                $wanted{_settings_key(\%settings)} = 1;
            }

            push @$ret, \%settings;
        }
    }

    $ret = _sort_dep($ret);
    # the array is sorted parents first - iterate it backward
    for (my $i = $#{$ret}; $i >= 0; $i--) {
        if ($wanted{_settings_key($ret->[$i])}) {
            # add parents to wanted list
            my @parents;
            push @parents, _parse_dep_variable($ret->[$i]->{START_AFTER_TEST}, $ret->[$i]);
            push @parents, _parse_dep_variable($ret->[$i]->{PARALLEL_WITH},    $ret->[$i]);
            for my $p (@parents) {
                $wanted{$p} = 1;
            }
        }
        else {
            splice @$ret, $i, 1;    # not wanted - delete
        }
    }
    return $ret;
}

sub job_create_dependencies {
    my ($self, $job, $testsuite_mapping) = @_;

    my $settings = $job->settings_hash;
    for my $depname ('START_AFTER_TEST', 'PARALLEL_WITH') {
        next unless defined $settings->{$depname};
        for my $testsuite (_parse_dep_variable($settings->{$depname}, $settings)) {
            if (!defined $testsuite_mapping->{$testsuite}) {
                warn sprintf('%s=%s not found - check for typos and dependency cycles', $depname, $testsuite);
            }
            else {
                my $dep;
                if ($depname eq 'START_AFTER_TEST') {
                    $dep = OpenQA::Schema::Result::JobDependencies::CHAINED;
                }
                elsif ($depname eq 'PARALLEL_WITH') {
                    $dep = OpenQA::Schema::Result::JobDependencies::PARALLEL;
                }
                else {
                    die 'Unknown dependency type';
                }
                for my $parent (@{$testsuite_mapping->{$testsuite}}) {

                    $self->app->db->resultset('JobDependencies')->create(
                        {
                            child_job_id  => $job->id,
                            parent_job_id => $parent,
                            dependency    => $dep,
                        });
                }
            }
        }
    }
}


# internal function not exported - but called by create
sub schedule_iso {
    my ($self, $args) = @_;
    # register assets posted here right away, in case no job
    # templates produce jobs.
    for my $a (values %{parse_assets_from_settings($args)}) {
        OpenQA::Scheduler::Scheduler::asset_register(%$a);
    }
    my $noobsolete = delete $args->{_NOOBSOLETEBUILD};
    # Any arg name ending in _URL is special: it tells us to download
    # the file at that URL before running the job
    my %downloads = ();
    for my $arg (keys %$args) {
        next unless ($arg =~ /_URL$/);
        # As this comes in from an API call, URL will be URI-encoded
        # This obviously creates a vuln if untrusted users can POST
        $args->{$arg} = url_unescape($args->{$arg});
        my $url = $args->{$arg};
        # if $args{FOO_URL} is set but $args{FOO} is not, we will
        # set $args{FOO} (the filename of the downloaded asset) to
        # the URL filename. This has to happen *before*
        # generate_jobs so the jobs have FOO set
        my $short = substr($arg, 0, -4);
        my $assettype = asset_type_from_setting($short);
        # We're only going to allow downloading of asset types
        unless ($assettype) {
            OpenQA::Utils::log_debug("_URL downloading only allowed for asset types! $short is not an asset type");
            next;
        }
        if (!$args->{$short}) {
            $args->{$short} = Mojo::URL->new($url)->path->parts->[-1];
            if (!$args->{$short}) {
                OpenQA::Utils::log_warning("Unable to get filename from $url. Ignoring $arg");
                delete $args->{$short} unless $args->{$short};
                next;
            }
        }
        # full path to download target location. We need to guess
        # the asset type to know where to put it, using the same
        # subroutine as parse_assets_from_settings
        my $dir = catdir($OpenQA::Utils::assetdir, $assettype);
        my $fullpath = catfile($dir, $args->{$short});

        unless (-s $fullpath) {
            # if the file doesn't exist, add the url/target path
            # as a key/value pair to the %downloads hash
            $downloads{$url} = $fullpath;
        }
    }
    my $jobs = $self->_generate_jobs($args);

    # XXX: take some attributes from the first job to guess what old jobs to
    # cancel. We should have distri object that decides which attributes are
    # relevant here.
    if (!$noobsolete && $jobs && $jobs->[0] && $jobs->[0]->{BUILD}) {
        my %cond;
        for my $k (qw/DISTRI VERSION FLAVOR ARCH/) {
            next unless $jobs->[0]->{$k};
            $cond{$k} = $jobs->[0]->{$k};
        }
        if (%cond) {
            OpenQA::Scheduler::Scheduler::job_cancel(\%cond, 1);    # have new build jobs instead
        }
    }

    # the jobs are now sorted parents first

    my @ids     = ();
    my $coderef = sub {
        my @jobs = ();
        # remember ids of created parents
        my %testsuite_ids;                                          # key: "suite:machine", value: array of job ids

        for my $settings (@{$jobs || []}) {
            my $prio     = delete $settings->{PRIO};
            my $group_id = delete $settings->{GROUP_ID};

            # create a new job with these parameters and count if successful, do not send job notifies yet
            my $job = OpenQA::Scheduler::Scheduler::job_create($settings, 1);

            if ($job) {
                push @jobs, $job;

                $testsuite_ids{_settings_key($settings)} //= [];
                push @{$testsuite_ids{_settings_key($settings)}}, $job->id;

                # change prio only if other than default prio
                if (defined($prio) && $prio != 50) {
                    $job->priority($prio);
                }
                $job->group_id($group_id);
                $job->update;
            }
        }

        # jobs are created, now recreate dependencies and extract ids
        for my $job (@jobs) {
            $self->job_create_dependencies($job, \%testsuite_ids);
            push @ids, $job->id;
        }

        # enqueue gru jobs
        if (%downloads and @ids) {
            # array of hashrefs job_id => id; this is what create needs
            # to create entries in a related table (gru_dependencies)
            my @jobsarray = map +{job_id => $_}, @ids;
            for my $url (keys %downloads) {
                my $path = $downloads{$url};
                $self->app->db->resultset('GruTasks')->create(
                    {
                        taskname => 'download_asset',
                        priority => 20,
                        args     => [$url, $path],
                        run_at   => now(),
                        jobs     => \@jobsarray,
                    });
            }
        }
    };

    try {
        $self->app->db->txn_do($coderef);
    }
    catch {
        my $error = shift;
        OpenQA::Utils::log_debug("rollback job_schedule_iso: $error");
        die "Rollback failed during failed job_schedule_iso: $error"
          if ($error =~ /Rollback failed/);
        @ids = ();
    };

    $self->app->db->resultset('GruTasks')->create(
        {
            taskname => 'limit_assets',
            priority => 10,
            args     => [],
            run_at   => now(),
        });

    # if the notification fails
    try {
        #notify workers new jobs are available
        job_notify_workers;
    }
    catch {
        $self->app->log->warn("Failed to notify workers");
    };
    return @ids;
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
            $error .= ' ' . $k if $validation->has_error($k);
        }
        $self->res->message($error);
        return $self->rendered(400);
    }

    my $params = $self->req->params->to_hash;
    # job_create expects upper case keys
    my %up_params = map { uc $_ => $params->{$_} } keys %$params;
    # restore URL encoded /
    my %params = map { $_ => $up_params{$_} =~ s@%2F@/@gr } keys %up_params;

    my @check = check_download_whitelist(\%params, $self->app->config->{global}->{download_domains});
    if (@check) {
        my ($status, $param, $url, $host) = @check;
        if ($status == 2) {
            my $error = "Asset download requested but no domains whitelisted! Set download_domains";
            $self->app->log->debug("$param - $url");
            $self->res->message($error);
            return $self->rendered(403);
        }
        else {
            my $error = "Asset download requested from non-whitelisted host $host";
            $self->app->log->debug("$param - $url");
            $self->res->message($error);
            return $self->rendered(403);
        }
    }

    $self->emit_event('openqa_iso_create', \%params);

    my @ids = $self->schedule_iso(\%params);
    my $cnt = scalar(@ids);

    $self->app->log->debug("created $cnt jobs");
    $self->render(json => {count => $cnt, ids => \@ids});
}

sub destroy {
    my $self = shift;
    my $iso  = $self->stash('name');
    my $ipc  = OpenQA::IPC->ipc;
    $self->emit_event('openqa_iso_delete', {iso => $iso});

    my $res = $ipc->scheduler('job_delete_by_iso', $iso);
    $self->render(json => {count => $res});
}

sub cancel {
    my $self = shift;
    my $iso  = $self->stash('name');
    my $ipc  = OpenQA::IPC->ipc;
    $self->emit_event('openqa_iso_cancel', {iso => $iso});

    my $res = $ipc->scheduler('job_cancel_by_iso', $iso, 0);
    $self->render(json => {result => $res});
}

1;
# vim: set sw=4 et:
