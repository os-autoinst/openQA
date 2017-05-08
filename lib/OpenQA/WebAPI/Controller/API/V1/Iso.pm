# Copyright (C) 2015-2016 SUSE LLC
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
use File::Basename;

use OpenQA::Utils;
use OpenQA::IPC;
use Try::Tiny;
use DBIx::Class::Timestamps 'now';
use OpenQA::Schema::Result::JobDependencies;

use Carp;

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

    my @products = $self->db->resultset('Products')->search(
        {
            distri  => lc($args->{DISTRI}),
            version => $args->{VERSION},
            flavor  => $args->{FLAVOR},
            arch    => $args->{ARCH},
        });

    unless (@products) {
        OpenQA::Utils::log_warning('no products found, retrying version wildcard');
        @products = $self->db->resultset('Products')->search(
            {
                distri  => lc($args->{DISTRI}),
                version => '*',
                flavor  => $args->{FLAVOR},
                arch    => $args->{ARCH},
            });
    }

    if (!@products) {
        carp "no products found for " . join('-', map { $args->{$_} } qw(DISTRI VERSION FLAVOR ARCH));
    }

    my %wanted;    # jobs specified by $args->{TEST} or $args->{MACHINE} or their parents

    # Allow a comma separated list of tests here; whitespaces allowed
    my @tests = $args->{TEST} ? split(/\s*,\s*/, $args->{TEST}) : ();

    for my $product (@products) {
        my @templates = $product->job_templates;
        unless (@templates) {
            carp "no templates found for " . join('-', map { $args->{$_} } qw(DISTRI VERSION FLAVOR ARCH));
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

            # allow some messing with the usual precedence order. If anything
            # sets +VARIABLE, that setting will be used as VARIABLE regardless
            # (so a product or template +VARIABLE beats a post'ed VARIABLE).
            # if *multiple* things set +VARIABLE, whichever comes highest in
            # the usual precedence order wins.
            for (keys %settings) {
                if (substr($_, 0, 1) eq '+') {
                    $settings{substr($_, 1)} = delete $settings{$_};
                }
            }

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

            if (!$args->{MACHINE} || $args->{MACHINE} eq $settings{MACHINE}) {
                if (!@tests) {
                    $wanted{_settings_key(\%settings)} = 1;
                }
                else {
                    foreach my $test (@tests) {
                        if ($test eq $settings{TEST}) {
                            $wanted{_settings_key(\%settings)} = 1;
                            last;
                        }
                    }
                }
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

    my @error_messages;
    my $settings = $job->settings_hash;
    for my $dependency (
        ['START_AFTER_TEST', OpenQA::Schema::Result::JobDependencies::CHAINED],
        ['PARALLEL_WITH',    OpenQA::Schema::Result::JobDependencies::PARALLEL])
    {
        my ($depname, $deptype) = @$dependency;
        next unless defined $settings->{$depname};
        for my $testsuite (_parse_dep_variable($settings->{$depname}, $settings)) {
            if (!defined $testsuite_mapping->{$testsuite}) {
                my $error_msg = "$depname=$testsuite not found - check for typos and dependency cycles";
                OpenQA::Utils::log_warning($error_msg);
                push(@error_messages, $error_msg);
            }
            else {
                for my $parent (@{$testsuite_mapping->{$testsuite}}) {
                    $self->db->resultset('JobDependencies')->create(
                        {
                            child_job_id  => $job->id,
                            parent_job_id => $parent,
                            dependency    => $deptype,
                        });
                }
            }
        }
    }
    return \@error_messages;
}


# internal function not exported - but called by create
sub schedule_iso {
    my ($self, $args) = @_;
    # register assets posted here right away, in case no job
    # templates produce jobs.
    for my $a (values %{parse_assets_from_settings($args)}) {
        $self->app->schema->resultset("Assets")->register($a->{type}, $a->{name}, 1);
    }
    my $deprioritize       = delete $args->{_DEPRIORITIZEBUILD} // 0;
    my $deprioritize_limit = delete $args->{_DEPRIORITIZE_LIMIT};
    my $obsolete           = !(delete $args->{_NOOBSOLETEBUILD} // $deprioritize);

    # Any arg name ending in _URL is special: it tells us to download
    # the file at that URL before running the job
    my %downloads = ();
    for my $arg (keys %$args) {
        next unless ($arg =~ /_URL$/);
        # As this comes in from an API call, URL will be URI-encoded
        # This obviously creates a vuln if untrusted users can POST
        $args->{$arg} = url_unescape($args->{$arg});
        my $url        = $args->{$arg};
        my $do_extract = 0;
        my $short;
        my $filename;
        # if $args{FOO_URL} or $args{FOO_DECOMPRESS_URL} is set but $args{FOO}
        # is not, we will set $args{FOO} (the filename of the downloaded asset)
        # to the URL filename. This has to happen *before*
        # generate_jobs so the jobs have FOO set
        if ($arg =~ /_DECOMPRESS_URL$/) {
            $do_extract = 1;
            $short = substr($arg, 0, -15);    # remove whole _DECOMPRESS_URL substring
        }
        else {
            $short = substr($arg, 0, -4);    # remove _URL substring
        }
        # We're only going to allow downloading of asset types. We also
        # need this to determine the download location later
        my $assettype = asset_type_from_setting($short);
        unless ($assettype) {
            OpenQA::Utils::log_debug("_URL downloading only allowed for asset types! $short is not an asset type");
            next;
        }
        if (!$args->{$short}) {
            $filename = Mojo::URL->new($url)->path->parts->[-1];
            if ($do_extract) {
                # if user wants to extract downloaded file, final filename
                # will have last extension removed
                $filename = fileparse($filename, qr/\.[^.]*/);
            }
            $args->{$short} = $filename;
            if (!$args->{$short}) {
                OpenQA::Utils::log_warning("Unable to get filename from $url. Ignoring $arg");
                delete $args->{$short} unless $args->{$short};
                next;
            }
        }
        else {
            $filename = $args->{$short};
        }
        # Find where we should download the file to
        my $fullpath = locate_asset($assettype, $filename, mustexist => 0);

        unless (-s $fullpath) {
            # if the file doesn't exist, add the url/target path and extraction
            # flag as a key/value pair to the %downloads hash
            $downloads{$url} = [$fullpath, $do_extract];
        }
    }
    my $jobs = $self->_generate_jobs($args);

    # XXX: take some attributes from the first job to guess what old jobs to
    # cancel. We should have distri object that decides which attributes are
    # relevant here.

    if (($obsolete || $deprioritize) && $jobs && $jobs->[0] && $jobs->[0]->{BUILD}) {
        my $build = $jobs->[0]->{BUILD};
        OpenQA::Utils::log_debug(
            "Triggering new iso with build \'$build\', obsolete: $obsolete, deprioritize: $deprioritize");
        my %cond;
        for my $k (qw(DISTRI VERSION FLAVOR ARCH)) {
            next unless $jobs->[0]->{$k};
            $cond{$k} = $jobs->[0]->{$k};
        }
        if (%cond) {
            # Prefer new build jobs over old ones either by cancelling old
            # ones or deprioritizing them (up to a limit)
            try {
                $self->emit_event('openqa_iso_cancel', \%cond);
                $self->db->resultset('Jobs')->cancel_by_settings(\%cond, 1, $deprioritize, $deprioritize_limit);
            }
            catch {
                my $error = shift;
                $self->app->log->warn("Failed to cancel old jobs: $error");
            };
        }
    }

    # the jobs are now sorted parents first

    my @successful_job_ids;
    my @failed_job_info;
    my $coderef = sub {
        my @jobs;
        # remember ids of created parents
        my %testsuite_ids;    # key: "suite:machine", value: array of job ids

        for my $settings (@{$jobs || []}) {
            my $prio = delete $settings->{PRIO};
            $settings->{_GROUP_ID} = delete $settings->{GROUP_ID};

            # create a new job with these parameters and count if successful, do not send job notifies yet
            my $job = $self->db->resultset('Jobs')->create_from_settings($settings);
            push @jobs, $job;

            $testsuite_ids{_settings_key($settings)} //= [];
            push @{$testsuite_ids{_settings_key($settings)}}, $job->id;

            # set prio if defined explicitely (otherwise default prio is used)
            if (defined($prio)) {
                $job->priority($prio);
            }
            $job->update;
        }

        # jobs are created, now recreate dependencies and extract ids
        for my $job (@jobs) {
            my $error_messages = $self->job_create_dependencies($job, \%testsuite_ids);
            if (!@$error_messages) {
                push(@successful_job_ids, $job->id);
            }
            else {
                push(
                    @failed_job_info,
                    {
                        job_id         => $job->id,
                        error_messages => $error_messages
                    });
            }
        }

        # enqueue gru jobs
        if (%downloads and @successful_job_ids) {
            # array of hashrefs job_id => id; this is what create needs
            # to create entries in a related table (gru_dependencies)
            my @jobsarray = map +{job_id => $_}, @successful_job_ids;
            for my $url (keys %downloads) {
                my ($path, $do_extract) = @{$downloads{$url}};
                $self->db->resultset('GruTasks')->create(
                    {
                        taskname => 'download_asset',
                        priority => 20,
                        args     => [$url, $path, $do_extract],
                        run_at   => now(),
                        jobs     => \@jobsarray,
                    });
            }
        }
    };

    try {
        $self->db->txn_do($coderef);
    }
    catch {
        my $error = shift;
        $self->app->log->warn("Failed to schedule ISO: $error");
        push(@failed_job_info, map { {job_id => $_, error_messages => [$error],} } @successful_job_ids);
        @successful_job_ids = ();
    };

    $self->db->resultset('GruTasks')->create(
        {
            taskname => 'limit_assets',
            priority => 10,
            args     => [],
            run_at   => now(),
        });
    $self->db->resultset('GruTasks')->create(
        {
            taskname => 'limit_results_and_logs',
            priority => 5,
            args     => [],
            run_at   => now(),
        });

    notify_workers;
    $self->emit_event('openqa_iso_create', $args);
    return {
        successful_job_ids => \@successful_job_ids,
        failed_job_info    => \@failed_job_info,
    };
}

sub create {
    my ($self) = @_;

    my $validation = $self->validation;
    $validation->required('DISTRI');
    $validation->required('VERSION');
    $validation->required('FLAVOR');
    $validation->required('ARCH');
    if ($validation->has_error) {
        my $error = "Error: missing parameters:";
        for my $k (qw(DISTRI VERSION FLAVOR ARCH)) {
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

    my $scheduled_jobs     = $self->schedule_iso(\%params);
    my $successful_job_ids = $scheduled_jobs->{successful_job_ids};
    my $failed_job_info    = $scheduled_jobs->{failed_job_info};
    my $created_job_count  = scalar(@$successful_job_ids);

    my $debug_message = "Created $created_job_count jobs";
    if (my $failed_job_count = scalar(@$failed_job_info)) {
        $debug_message .= " but failed to create $failed_job_count jobs";
    }
    $self->app->log->debug($debug_message);

    $self->render(
        json => {
            count  => $created_job_count,
            ids    => $successful_job_ids,
            failed => $failed_job_info,
        });
}

sub destroy {
    my $self = shift;
    my $iso  = $self->stash('name');
    $self->emit_event('openqa_iso_delete', {iso => $iso});

    my $subquery = $self->db->resultset("JobSettings")->query_for_settings({ISO => $iso});
    my @jobs
      = $self->db->resultset("Jobs")->search({'me.id' => {-in => $subquery->get_column('job_id')->as_query}})->all;

    for my $job (@jobs) {
        $self->emit_event('openqa_job_delete', {id => $job->id});
        $job->delete;
    }
    $self->render(json => {count => scalar(@jobs)});
}

sub cancel {
    my $self = shift;
    my $iso  = $self->stash('name');
    my $ipc  = OpenQA::IPC->ipc;
    $self->emit_event('openqa_iso_cancel', {iso => $iso});

    my $res = $self->db->resultset('Jobs')->cancel_by_settings({ISO => $iso}, 0);
    $self->render(json => {result => $res});
}

1;
# vim: set sw=4 et:
