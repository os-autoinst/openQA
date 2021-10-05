# SUSE's openQA tests
#
# Copyright 2009-2013 Bernhard M. Wiedemann
# Copyright 2012-2017 SUSE LLC
#
# Copying and distribution of this file, with or without modification,
# are permitted in any medium without royalty provided the copyright
# notice and this notice are preserved.  This file is offered as-is,
# without any warranty.

# Package: kate
# Summary: Test the KDE text editor can be installed, started, typing works
#   and closed
# Maintainer: Oliver Kurz <okurz@suse.de>

use strict;
use warnings;

sub run {
    my @regexp = qw(test-kate-3 tes-module_re);
}

1;
