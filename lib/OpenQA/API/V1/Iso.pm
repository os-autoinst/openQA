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

package OpenQA::API::V1::Iso;
use Mojo::Base 'Mojolicious::Controller';
use openqa;
use Scheduler ();
use Try::Tiny;

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
                version => '*',
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

            # ISO_MAXSIZE can have the separator _
            if (exists $settings{ISO_MAXSIZE}) {
                $settings{ISO_MAXSIZE} =~ s/_//g;
            }

            for (keys  %args) {
                $settings{uc $_} = $args{$_};
            }
            # Makes sure tha the DISTRI is lowercase
            $settings{DISTRI} = lc($settings{DISTRI});

            $settings{PRIO} = $job_template->test_suite->prio;

            # XXX: hack, maybe use http proxy instead!?
            if ($settings{NETBOOT} && !$settings{SUSEMIRROR} && $self->app->config->{global}->{suse_mirror}) {
                my $repourl = $self->app->config->{global}->{suse_mirror}."/iso/".$args{ISO};
                $repourl =~ s/-Media\.iso$//;
                $repourl .= '-oss';
                $settings{SUSEMIRROR} = $repourl;
                $settings{FULLURL} = 1;
            }

            push @$ret, \%settings;
        }
    }

    return $ret;
}


sub create {
    my $self = shift;

    my $validation = $self->validation;
    $validation->required('ISO');
    $validation->required('DISTRI');
    $validation->required('VERSION');
    $validation->required('FLAVOR');
    $validation->required('ARCH');
    if ($validation->has_error) {
        my $error = "Error: missing parameters:";
        for my $k (qw/ISO DISTRI VERSION FLAVOR ARCH/) {
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
            Scheduler::job_cancel(\%cond);
        }
    }

    my $cnt = 0;
    my @ids;
    for my $settings (@{$jobs||[]}) {
        my $prio = $settings->{PRIO};
        delete $settings->{PRIO};
        # create a new job with these parameters and count if successful
        my $id;
        try {
            $id = Scheduler::job_create(%$settings);
        }
        catch {
            chomp;
            $self->app->log->error("job_create: $_");
        };
        if ($id) {
            $cnt++;
            push @ids, $id;
            # change prio only if other than defalt prio
            if( $prio && $prio != 50 ) {
                Scheduler::job_set_prio(jobid => $id, prio => $prio);
            }
        }
    }
    $self->app->log->debug("created $cnt jobs");
    $self->render(json => {count => $cnt, ids => \@ids });
}

sub destroy {
    my $self = shift;
    my $iso = $self->stash('name');

    my $res = Scheduler::job_delete($iso);
    $self->render(json => {count => $res});
}

sub cancel {
    my $self = shift;
    my $iso = $self->stash('name');

    my $res = Scheduler::job_cancel($iso);
    $self->render(json => {result => $res});
}

1;
# vim: set sw=4 et:
