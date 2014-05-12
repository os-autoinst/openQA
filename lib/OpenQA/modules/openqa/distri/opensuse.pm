#!/usr/bin/env perl
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

package openqa::distri::opensuse;

use strict;
use warnings;
use Clone qw/clone/;
use openqa ();
use Data::Dump qw/pp/;

sub _regexp_parts{
    my $distri = '(openSUSE)';
    my $version = '([^-]+)';
    my $flavor = '(Addon-(?:Lang|NonOss)|(?:Promo-|Staging\d?-)?DVD(?:-BiArch|-OpenSourcePress)?|NET|(?:GNOME|KDE)-Live|Rescue-CD|MINI-ISO)';
    my $arch = '(i[356]86(?:-x86_64)?|x86_64|i586-x86_64)';
    my $build = '(?:Build|Snapshot)([^-]+)';

    return ($distri, $version, $flavor, $arch, $build);
}

sub parse_iso($) {
    my $iso = shift;

    # XXX: refactor this
    my $order = 1;
    my ($distri, $version, $flavor, $arch, $build) = _regexp_parts;

    my @parts = $iso =~ /^$distri(?:-$version)?-$flavor(?:-$build)?-$arch.*\.iso$/i;

    if (!$parts[3] ) {
        @parts = $iso =~ /^$distri(?:-$version)?-$flavor-$arch(?:-$build)?.*\.iso$/i;
        $order = 2;
    }

    my %params;
    if(@parts) {
        if ($order == 1) {
            @params{qw(distri version flavor build arch)} = @parts;
        }
        else {
            @params{qw(distri version flavor arch build)} = @parts;
        }
        $params{version} ||= 'Factory';
    }

    return %params if (wantarray());
    return %params?\%params:undef;
}

# Convert a string in the form:
#
#   KEY1=VALUE1;KEY2=VALUE2
#
# into a hash:
#
#   { KEY1 => VALUE1, KEY2 => VALUE2 }
sub _str_to_hash {
    my $str = shift;
    my %hash = split(/[=;]/, $str);
    return %hash;
}

sub generate_jobs {
    my $class = shift;
    my $app = shift;

    my %args = @_;
    my $iso = $args{'iso'} or die "missing parmeter iso\n";
    my @requested_runs = @{ $args{'requested_runs'} || [] };

    my $ret = [];

    # parse the iso filename
    my $params = parse_iso($iso);
    $app->log->debug("parsed iso params: ". join('|', %{$params//{}}));
    return $ret unless $params;

    my $schema = openqa::connect_db();
    my @products = $schema->resultset('Products')->search(
        {
            arch => $params->{arch},
            distri => lc($params->{distri}),
            flavor => $params->{flavor},
        }
    );

    $app->log->debug("products: ". join(',', map { $_->name } @products));

    foreach my $product (@products) {
        foreach my $job_template ($product->job_templates) {
            my %settings = _str_to_hash($product->variables);

            my %tmp_settings = _str_to_hash($job_template->machine->variables);
            @settings{keys %tmp_settings} = values %tmp_settings;

            %tmp_settings = map { $_->key => $_->value } $job_template->test_suite->settings;
            @settings{keys %tmp_settings} = values %tmp_settings;
            $settings{TEST} = $job_template->test_suite->name;
            $settings{MACHINE} = $job_template->machine->name;

            # ISO_MAXSIZE can have the separator _
            if (exists $settings{ISO_MAXSIZE}) {
                $settings{ISO_MAXSIZE} =~ s/_//g;
            }

            for (keys  %$params) {
                $settings{uc $_} = $params->{$_};
            }
            # Makes sure tha the DISTRI is lowercase
            $settings{DISTRI} = lc($settings{DISTRI});

            $settings{PRIO} = $job_template->test_suite->prio;
            $settings{ISO} = $iso;

            # XXX: hack, maybe use http proxy instead!?
            if ($settings{NETBOOT} && !$settings{SUSEMIRROR} && $app->config->{global}->{suse_mirror}) {
                my $repourl = $app->config->{global}->{suse_mirror}."/iso/".$iso;
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

1;

# vim: set sw=4 et:
