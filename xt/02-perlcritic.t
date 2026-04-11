# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;
use Test::Warnings qw(:no_end_test :report_warnings);
use FindBin '$Bin';
use lib "$Bin/../external/os-autoinst-common/lib/perlcritic";
use Test::Perl::Critic;
my @files = sort grep { ! -l $_ } grep { ! m{^(?:t/data/)} } Perl::Critic::Utils::all_perl_files(qw(lib t))
    or fail 'Find perl files';
all_critic_ok(@files);
