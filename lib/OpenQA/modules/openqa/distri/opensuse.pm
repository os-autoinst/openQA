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

sub _regexp_parts
{
    my $distri = '(openSUSE)';
    my $version = '(\d+(?:\.\d)?|Factory)';
    my $flavor = '(Addon-(?:Lang|NonOss)|(?:Promo-)?DVD(?:-BiArch|-OpenSourcePress)?|NET|(?:GNOME|KDE)-Live|Rescue-CD|MINI-ISO|staging_[^-]+)';
    my $arch = '(i[356]86(?:-x86_64)?|x86_64|i586-x86_64)';
    my $build = 'Build([0-9.]+)';

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
    if( @parts ) {
	if ($order == 1) {
	    @params{qw(distri version flavor build arch)} = @parts;
	} else {
	    @params{qw(distri version flavor arch build)} = @parts;
	}
	$params{version} ||= 'Factory';
    }

    return %params if (wantarray());
    return %params?\%params:undef;
}

# look at iso file name and create jobs suitable for this iso image
# parameter is a hash with the keys
#   iso => "name of the iso image"
#   requested_runs => [ "name of test runs", ... ]
sub generate_jobs
{
    my $class = shift;
    my $config = shift;

    my %args = @_;
    my $iso = $args{'iso'} or die "missing parmeter iso\n";
    my @requested_runs = @{$args{'requested_runs'}||[]};

    my $ret = [];

    my $default_prio = 50;

    ### definition of special tests
    my %testruns = (
        textmode => {
            applies => sub { $_[0]->{flavor} !~ /Live|Promo/ },
            settings => {'DESKTOP' => 'textmode',
                         'VIDEOMODE' => 'text'},
            prio => $default_prio - 10 },
        kde => {
            applies => '$iso{flavor} !~ /GNOME/',
            settings => {
		'DESKTOP' => 'kde'
	    },
            prio => $default_prio - 10 },
        uefi => {
            applies => sub { $_[0]->{arch} =~ /x86_64/ && $_[0]->{flavor} !~ /Live/ },
	    prio => $default_prio - 5,
            settings => {
                'QEMUCPU' => 'qemu64',
                'UEFI' => '1',
                'DESKTOP' => 'kde',
		'INSTALLONLY' => 1, # XXX
            } },
        'kde+usb' => {
            applies => sub { $_[0]->{flavor} !~ /GNOME/ },
            settings => {
		DESKTOP => 'kde',
		'USBBOOT' => '1',
	    },
	    prio => $default_prio - 5,
	    },
        'kde+btrfs' => {
            applies => '$iso{flavor} !~ /GNOME/',
            settings => {
		    'DESKTOP' => 'kde',
		    'HDDSIZEGB' => '20',
		    'BTRFS' => 1,
	    } },
        gnome => {
            applies => sub { $_[0]->{flavor} !~ /KDE/ },
            settings => {'DESKTOP' => 'gnome', 'LVM' => '1'},
            prio => $default_prio - 5, },
        'gnome+usb' => {
            applies => sub { $_[0]->{flavor} =~ /GNOME/ },
	    prio => $default_prio - 5,
            settings => {
		DESKTOP => 'gnome',
		'USBBOOT' => '1',
		} },
        'gnome+btrfs' => {
            applies => sub { $_[0]->{flavor} !~ /KDE/ },
            settings => {
		    'DESKTOP' => 'gnome',
		    'LVM' => '1',
		    'HDDSIZEGB' => '20',
		    'BTRFS' => '1'
	    } },
        minimalx => {
            applies => sub { $_[0]->{flavor} !~ /Live/ },
            settings => {'DESKTOP' => 'minimalx'},
            prio => $default_prio - 5 },
        "minimalx+btrfs" => {
            applies => sub { $_[0]->{flavor} !~ /Live/ },
            settings => {
                    'DESKTOP' => 'minimalx',
		    'HDDSIZEGB' => '20',
                    'BTRFS' => '1'
                    },
            },
	"minimalx+btrfs+nosephome" => {
            applies => sub { $_[0]->{flavor} eq 'DVD' },
            settings => {
                    'DESKTOP' => 'minimalx',
		    'INSTALLONLY' => '1',
		    'HDDSIZEGB' => '20',
		    'TOGGLEHOME' => '1',
                    'BTRFS' => '1'
                    },
            },
        'textmode+btrfs' => {
            applies => sub { $_[0]->{flavor} !~ /Live|Promo/ },
            settings => {
                    'DESKTOP' => 'textmode',
		    'HDDSIZEGB' => '20',
                    'BTRFS' => '1',
                    'VIDEOMODE' => 'text'
                    },
            },
        lxde => {
            applies => sub { $_[0]->{flavor} !~ /Live|Promo/ },
            settings => {'DESKTOP' => 'lxde',
                         'LVM' => '1'},
            prio => $default_prio - 1 },
        xfce => {
            applies => sub { $_[0]->{flavor} !~ /Live|Promo/ },
            settings => {'DESKTOP' => 'xfce'},
            prio => $default_prio - 1 },
        'gnome+laptop' => {
            applies => sub { $_[0]->{flavor} !~ /KDE/ },
            settings => {'DESKTOP' => 'gnome', 'LAPTOP' => '1'},
            },
        'kde+laptop' => {
            applies => sub { $_[0]->{flavor} !~ /GNOME/ },
            settings => {'DESKTOP' => 'kde', 'LAPTOP' => '1'},
            },
        64 => {
            applies => '$iso{flavor} =~ /Biarch/',
            settings => {'QEMUCPU' => 'qemu64'} },
        RAID0 => {
            applies => sub { $_[0]->{flavor} !~ /Promo/ },
            settings => {
                    'RAIDLEVEL' => '0',
		    'INSTALLONLY' => '1',
            } },
        RAID1 => {
            applies => sub { $_[0]->{flavor} !~ /Promo/ },
	    prio => $default_prio + 1,
            settings => {
                    'RAIDLEVEL' => '1',
		    'INSTALLONLY' => '1',
            } },
        RAID5 => {
            applies => sub { $_[0]->{flavor} !~ /Promo/ },
	    prio => $default_prio + 1,
            settings => {
                    'RAIDLEVEL' => '5',
		    'INSTALLONLY' => '1',
            } },
        RAID10 => {
            applies => sub { $_[0]->{flavor} !~ /Promo/ },
	    prio => $default_prio + 1,
            settings => {
                    'RAIDLEVEL' => '10',
		    'INSTALLONLY' => '1',
            } },
        btrfscryptlvm => {
            applies => sub { $_[0]->{flavor} !~ /Promo/ },
            settings => {'BTRFS' => '1',
                         'HDDSIZEGB' => '20',
                         'ENCRYPT' => '1',
                         'LVM' => '1',
                         'NICEVIDEO' => '1',
                 } },
        cryptlvm => {
            applies => sub { $_[0]->{flavor} !~ /Promo/ },
            settings => {'REBOOTAFTERINSTALL' => '0',
                         'ENCRYPT' => '1',
                         'LVM' => '1',
                         'NICEVIDEO' => '1',
                 } },
        doc_de => {
            applies => 0,
            settings => {'DOCRUN' => '1',
                         'INSTLANG' => 'de_DE',
                         'QEMUVGA' => 'std'} },
        doc => {
            applies => sub { $_[0]->{flavor} eq 'DVD' && $_[0]->{arch} =~ /x86_64/ },
	    prio => $default_prio + 10,
            settings => {'DOCRUN' => '1',
                         'QEMUVGA' => 'std'} },
        'kde-live' => {
            applies => sub { $_[0]->{flavor} =~ /KDE-Live|Promo/ },
	    prio => $default_prio - 2,
            settings => {
		'DESKTOP' => 'kde',
		'LIVETEST' => '1',
		} },
        'gnome-live' => {
            applies => sub { $_[0]->{flavor} =~ /GNOME-Live|Promo/ },
	    prio => $default_prio - 2,
            settings => {
		'DESKTOP' => 'gnome',
		'LIVETEST' => '1',
		} },
        rescue => {
	    prio => $default_prio - 1,
            applies => sub { $_[0]->{flavor} =~ /Rescue/ }, # Note: special case handled below
            settings => {'DESKTOP' => 'xfce',
                         'LIVETEST' => '1',
                         'RESCUECD' => '1',
                         'NOAUTOLOGIN' => '1',
                         'REBOOTAFTERINSTALL' => '0'} },
        nice => {
            applies => sub { $_[0]->{flavor} eq 'DVD' && $_[0]->{arch} =~ /x86_64/ },
            settings => {'NICEVIDEO' => '1',
                         'DOCRUN' => '1',
                         'REBOOTAFTERINSTALL' => '0',
                         'SCREENSHOTINTERVAL' => '0.25'} },
        smp => {
            applies => sub { $_[0]->{flavor} !~ /Promo/ },
            settings => {
                'QEMUCPUS' => '4',
		'INSTALLONLY' => '1',
                'NICEVIDEO' => '1',
            } },
        splitusr => {
            applies => sub { $_[0]->{flavor} eq 'DVD' && $_[0]->{arch} =~ /x86_64/ },
            settings => {
                'SPLITUSR' => '1',
                'NICEVIDEO' => '1',
            } },
	update_121 => {
	    applies => sub { $_[0]->{flavor} !~ /Promo/ },
	    settings => {'UPGRADE' => '1',
			 'HDD_1' => 'openSUSE-12.1-x86_64.hda',
			 'HDDVERSION' => 'openSUSE-12.1',
			 'DESKTOP' => 'kde',
	    } },
	update_122 => {
	    applies => sub { $_[0]->{flavor} !~ /Promo/ },
	    settings => {'UPGRADE' => '1',
			 'HDD_1' => 'openSUSE-12.2-x86_64.hda',
			 'HDDVERSION' => 'openSUSE-12.2',
			 'DESKTOP' => 'kde',
	    } },
	update_123 => {
	    applies => sub { $_[0]->{flavor} !~ /Promo/ },
	    settings => {'UPGRADE' => '1',
			 'HDD_1' => 'openSUSE-12.3-x86_64.hda',
			 'HDDVERSION' => 'openSUSE-12.3',
			 'DESKTOP' => 'kde',
	    } },
	dual_windows8 => {
	    applies => sub { $_[0]->{flavor} !~ /Promo/ },
	    settings => {'DUALBOOT' => '1',
			 'HDD_1' => 'Windows-8.hda',
			 'HDDVERSION' => 'Windows 8',
			 'HDDMODEL' => 'ide-hd',
			 'NUMDISKS' => 1,
			 'DESKTOP' => 'kde',
	    } },
	# dual_windows8_uefi => {
	#     applies => sub { $_[0]->{flavor} !~ /Promo/ && $_[0]->{arch} =~ /x86_64/ },
	#     settings => {'DUALBOOT' => '1',
	# 		 'HDD_1' => 'Windows-8.hda',
	# 		 'HDDVERSION' => 'Windows 8',
	# 		 'HDDMODEL' => 'ide-hd',
	# 		 'NUMDISKS' => 1,
	# 		 'DESKTOP' => 'kde',
	# 		 'UEFI' => '1',
        # 	         'QEMUCPU' => 'qemu64',
	#     } },
        );


    # parse the iso filename
    my $params = parse_iso($iso);
    return $ret unless $params;

    @requested_runs = sort keys(%testruns) unless @requested_runs;

    ### iso-based test restrictions go here

    sub clone_testrun($;@)
    {
	my $run = shift;
	my %h = @_;

	my $settings = clone $run;

	while (my ($k, $v) = each %h) {
	    $settings->{settings}->{$k} = $v;
	}
	return $settings;
    }

    if($params->{flavor} =~ m/Rescue/i) {
	# Rescue_CD cannot be installed; so livetest only
        @requested_runs = grep(/rescue/, @requested_runs);
    } elsif($params->{flavor} eq 'Promo-DVD-OpenSourcePress') {
	# open source press is live only
        @requested_runs = grep (/live/, @requested_runs);
	my @cloned;
	for my $t (@requested_runs) {
	    my $name = $t.'-usb';
	    $testruns{$name} = clone_testrun($testruns{$t}, USBBOOT => 1);
	    push @cloned, $name;
	}
	push @requested_runs, @cloned;
	@cloned = ();
	for my $t (@requested_runs) {
	    my $name = $t.'-64bit';
	    $testruns{$name} = clone_testrun($testruns{$t}, QEMUCPU => 'qemu64');
	    push @cloned, $name;
	}
	for my $t (grep(1, @cloned)) {
	    my $name = $t;
	    $name =~ s/-64bit/-uefi/;
	    $testruns{$name} = clone_testrun($testruns{$t}, 'UEFI' => 1);
	    push @cloned, $name;
	}
	push @requested_runs, @cloned;

	for my $t (@requested_runs) {
	    $testruns{$t}->{settings}->{INSTALLONLY} = 1;
	    $testruns{$t}->{settings}->{OSP_SPECIAL} = 1;
	}
    } elsif($params->{flavor} =~ /Live/ || $params->{flavor} eq 'Promo-DVD') {
	my @cloned;
	for my $t (grep (/live/, @requested_runs)) {
	    my $name = $t.'-usb';
	    $testruns{$name} = clone_testrun($testruns{$t}, USBBOOT => 1, INSTALLONLY => 1);
	    push @cloned, $name;
	}
	push @requested_runs, @cloned;

	if ($params->{arch} eq 'x86_64') {
	    for my $t (grep (/live/, @requested_runs)) {
		my $name = $t;
		$name = $t.'-uefi';
		$testruns{$name} = clone_testrun($testruns{$t}, 'UEFI' => 1);
		push @cloned, $name;
	    }
	    push @requested_runs, @cloned;
	}

	# for promo make live tests install only as we already tested the
	# apps in the plain live cds.
	if ($params->{flavor} eq 'Promo-DVD') {
	    for my $t (@requested_runs) {
		$testruns{$t}->{settings}->{INSTALLONLY} = 1;
	    }
	}
    }

    # only continue if parsing the ISO filename was successful
    if ( $params ) {
        # go through all requested special tests or all of them if nothing requested
        foreach my $run ( @requested_runs ) {
            # ...->{applies} can be a function ref to be executed, a string to be eval'ed or
            # can even not exist.
            # if it results to true or does not exist the test is assumed to apply
            my $applies = 0;
            if ( defined $testruns{$run}->{applies} ) {
                if ( ref($testruns{$run}->{applies}) eq 'CODE' ) {
                    $applies = $testruns{$run}->{applies}->($params);
                } else {
                    my %iso = %$params;
                    $applies = eval $testruns{$run}->{applies};
                    warn "error in testrun '$run': $@" if $@;
                }
            } else {
                $applies = 1;
            }

            next unless $applies;

            # set defaults here:
            my %settings = ( ISO => $iso,
                             TEST => $run,
                             DESKTOP => 'kde' );

            for (keys %$params) {
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

            unless ($settings{ISO_MAXSIZE}) {
                my $maxsize = 737_280_000;
                if ($settings{ISO} =~ /-DVD/) {
                    if ($settings{ISO} =~ /-DVD-Biarch/) {
                        $maxsize=8_539_996_160;
                    } else {
                        $maxsize=4_700_372_992;
                    }
                }
                # live images are for 1G sticks
                if ($settings{ISO} =~ /-Live/ && $settings{ISO} !~ /CD/) {
                    $maxsize=999_999_999;
                }

                $settings{ISO_MAXSIZE} = $maxsize;
            }

	    push @$ret, \%settings;
        }

    }

    return $ret;
}

1;

# vim: set sw=4 sts=4 et:
