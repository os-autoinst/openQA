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

package openqa::distri::sles;

use strict;
use warnings;
use Clone qw/clone/;

sub parse_iso($){
    my $iso = shift;
    my %params;
    my $archre = 'i[356]86(?:-x86_64)?|x86_64|ia64|ppc64|s390x';
    if ($iso =~ /^(?<distri>SLE)-(?<version>12)-(?<flavor>[[:alpha:]]+)-(?<medium>DVD)-(?<arch>$archre)-Build(?<build>[0-9.]+)-Media1\.iso$/){
        my $distri;
        if ($+{flavor} eq 'Server') {
            $distri = 'SLES';
        }
        elsif ($+{flavor} eq 'Desktop') {
            $distri = 'SLED';
        }
        else {
            print STDERR "unhandled flavor $+{flavor}\n";
        }
        if ($distri) {
            @params{qw(distri version flavor build arch)} = ($distri, $+{version}, $+{medium}, $+{build}, $+{arch});
        }
    }

    return %params if (wantarray());
    return %params?\%params:undef;
}

# look at iso file name and create jobs suitable for this iso image
# parameter is a hash with the keys
#   iso => "name of the iso image"
#   requested_runs => [ "name of test runs", ... ]
sub generate_jobs{
    my $class = shift;
    my $config = shift;

    my %args = @_;
    my $iso = $args{'iso'} or die "missing parmeter iso\n";
    my @requested_runs = @{$args{'requested_runs'}||[]};

    my $ret = [];

    my $default_prio = 50;

    ### definition of special tests
    my %testruns = (
        uefi => {
            applies => sub { $_[0]->{arch} =~ /x86_64/},
            settings => {
                'QEMUCPU' => 'qemu64',
                'UEFI' => '1',
                'DESKTOP' => 'gnome',
                'INSTALLONLY' => 1, # XXX
            }
        },
        default => {
            settings => {
                'QEMUCPUS' => '2',
                'DESKTOP' => 'gnome'
            }
        },
    );

    # parse the iso filename
    my $params = parse_iso($iso);
    return $ret unless $params;

    @requested_runs = sort keys(%testruns) unless @requested_runs;

    # only continue if parsing the ISO filename was successful
    if ($params) {
        # go through all requested special tests or all of them if nothing requested
        foreach my $run (@requested_runs) {
            # ...->{applies} can be a function ref to be executed, a string to be eval'ed or
            # can even not exist.
            # if it results to true or does not exist the test is assumed to apply
            my $applies = 0;
            if ( defined $testruns{$run}->{applies} ) {
                if ( ref($testruns{$run}->{applies}) eq 'CODE' ) {
                    $applies = $testruns{$run}->{applies}->($params);
                }
                else {
                    my %iso = %$params;
                    $applies = eval $testruns{$run}->{applies};
                    warn "error in testrun '$run': $@" if $@;
                }
            }
            else {
                $applies = 1;
            }

            next unless $applies;

            # set defaults here:
            my %settings = (
                ISO => $iso,
                TEST => $run,
                DESKTOP => 'kde',
                ISO_MAXSIZE => 4_700_372_992,
            );

            for (keys $params) {
                $settings{uc $_} = $params->{$_};
            }

            $settings{DISTRI} = lc $settings{DISTRI} if $settings{DISTRI};

            if ($config->{global}->{suse_mirror}) {
                my $repodir = $iso;
                $repodir =~ s/-Media\.iso$//;
                $repodir .= '-oss';
                $settings{SUSEMIRROR} = $config->{global}->{suse_mirror}."/iso/$repodir";
                $settings{FULLURL} = 1;
            }

            # merge defaults form above with the settings from %testruns
            my $test_definition = $testruns{$run}->{settings};
            @settings{keys %$test_definition} = values %$test_definition;

            ## define some default envs

            # match i386, i586, i686 and Biarch-i586-x86_64
            if ($params->{arch} =~ m/i[3-6]86/) {
                $settings{QEMUCPU} ||= 'qemu32';
            }
            if($params->{flavor} =~ m/Live/i || $params->{flavor} =~ m/Rescue/i) {
                $settings{LIVECD}=1;
            }
            if ($params->{flavor} =~ m/Promo/i) {
                $settings{PROMO}=1;
            }
            $settings{FLAVOR} = $params->{flavor};
            if($params->{flavor}=~m/(DVD|NET|KDE|GNOME|LXDE|XFCE)/) {
                $settings{$1}=1;
                $settings{NETBOOT}=$settings{NET} if exists $settings{NET};

                if($settings{LIVECD}) {
                    $settings{DESKTOP}=lc($1);
                }
            }

            # default priority
            my $prio = $default_prio;

            # change prio if defined
            $prio = $testruns{$run}->{prio} if ($testruns{$run}->{prio});

            # prefer DVDs
            $prio -= 5 if($params->{flavor} eq 'DVD');

            # prefer staging even more
            $prio -= 10 if($params->{flavor}=~m/staging_/);

            $settings{PRIO} = $prio;

            push @$ret, \%settings;
        }

    }

    return $ret;
}

1;
# vim: set sw=4 et:
