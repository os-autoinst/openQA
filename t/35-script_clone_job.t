# Copyright (C) 2018 SUSE Linux GmbH
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

BEGIN {
    unshift @INC, 'lib';
}

use strict;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Test::More;
use OpenQA::Script;

my @argv           = qw(WORKER_CLASS=local HDD_1=new.qcow2 HDDSIZEGB=40);
my %options        = ('parental-inheritance' => '');
my %child_settings = (
    NAME         => '00000810-sle-15-Installer-DVD-x86_64-Build665.2-hpc_test@64bit',
    TEST         => 'hpc_test',
    HDD_1        => 'sle-15-x86_64-Build665.2-with-hpc.qcow2',
    HDDSIZEGB    => 20,
    WORKER_CLASS => 'qemu_x86_64',
);
my %parent_settings = (
    NAME         => '00000810-sle-15-Installer-DVD-x86_64-Build665.2-create_hpc@64bit',
    TEST         => 'create_hpc',
    HDD_1        => 'sle-15-x86_64-Build665.2-with-hpc.qcow2',
    HDDSIZEGB    => 20,
    WORKER_CLASS => 'qemu_x86_64',
);

subtest 'clone job apply settings tests' => sub {
    my %test_settings = %child_settings;
    $test_settings{HDD_1}        = 'new.qcow2';
    $test_settings{HDDSIZEGB}    = 40;
    $test_settings{WORKER_CLASS} = 'local';
    delete $test_settings{NAME};
    clone_job_apply_settings(\@argv, 0, \%child_settings, \%options);
    is_deeply(\%child_settings, \%test_settings, 'cloned child job with correct global setting and new settings');

    %test_settings = %parent_settings;
    $test_settings{WORKER_CLASS} = 'local';
    delete $test_settings{NAME};
    clone_job_apply_settings(\@argv, 1, \%parent_settings, \%options);
    is_deeply(\%parent_settings, \%test_settings, 'cloned parent job only take global setting');
};

done_testing();
