#!/usr/bin/env perl
# Copyright 2020 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;

use FindBin '$Bin';
use lib "$FindBin::Bin/lib", "$FindBin::Bin/../external/os-autoinst-common/lib";
use OpenQA::Test::TimeLimit '120';

plan skip_all => 'set HEAVY=1 to execute (takes longer)' unless $ENV{HEAVY};

my %allowed_types = (
    'text/x-perl' => 1,
    'text/x-python' => 1,
    'text/x-shellscript' => 1,
);

# Could also use MIME::Types, would be new dependency
chomp(my @types = qx{cd $Bin/../script; for i in *; do echo \$i; file --mime-type --brief \$i; done});

my %types = @types;
for my $key (keys %types) {
    delete $types{$key} unless $allowed_types{$types{$key}};
}

for my $script (sort keys %types) {
    my $out = qx{$Bin/../script/$script --help 2>&1};
    my $rc = $?;
    is($rc, 0, "Calling '$script --help' returns exit code 0")
      or diag "Output: $out";
    next if $script eq 'openqa-worker-cacheservice-minion';    # unfortunately ignores invalid arguments
    $out = qx{$Bin/../script/$script invalid-command --invalid-flag 2>&1};
    $rc = $?;
    isnt($rc, 0, "Calling '$script invalid-command --invalid-flag' returns non-zero exit code")
      or diag "Output: $out";
}

done_testing;
