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
is qx{git grep -I -L '^use Test::Most' t/**.t}, '', 'All tests use Test::Most';
is qx{git grep --all-match -e '^use Mojo::Base' -e 'use base'}, '', 'No redundant Mojo::Base+base';
is qx{git grep -I --all-match -e '^use Mojo::Base' -e 'use \\(strict\\|warnings\\);' ':!docs'}, '',
  'Only combined Mojo::Base+strict+warnings';
is qx{git grep -I -L '^use Test::Warnings' t/**.t ':!t/01-style.t'}, '', 'All tests use Test::Warnings';
is qx{git grep -I -l 'sub [a-z_A-Z0-9]\\+()' ':!docs/'}, '',
  'Consistent space before function signatures (this is not ensured by perltidy)';
done_testing;

