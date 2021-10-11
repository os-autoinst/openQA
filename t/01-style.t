#!/usr/bin/perl
# Copyright 2021 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;

ok system(qq{git grep -I -l 'Copyright \((C)\|(c)\|©\)' ':!COPYING' ':!external/'}) != 0,
  'No redundant copyright character';
ok
  system(
qq{git grep -I -l 'This program is free software.*if not, see <http://www.gnu.org/licenses/' ':!COPYING' ':!external/' ':!t/01-style.t'}
  ) != 0, 'No verbatim licenses in source files';
ok system(qq{git grep -I -l '[#/ ]*SPDX-License-Identifier ' ':!COPYING' ':!external/' ':!t/01-style.t'}) != 0,
  'SPDX-License-Identifier correctly terminated';
done_testing;
