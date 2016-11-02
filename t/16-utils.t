#!/usr/bin/env perl -w

# Copyright (C) 2016 SUSE LLC
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
use OpenQA::Utils;
use Test::More;

is bugurl('bsc#1234'), 'https://bugzilla.suse.com/show_bug.cgi?id=1234', 'bug url is properly expanded';
ok find_bugref('gh#os-autoinst/openQA#1234'),                             'github bugref is recognized';
is bugurl('gh#os-autoinst/openQA#1234'),                                  'https://github.com/os-autoinst/openQA/issues/1234';
is bugurl('poo#1234'),                                                    'https://progress.opensuse.org/issues/1234';
is href_to_bugref('https://progress.opensuse.org/issues/1234'),           'poo#1234';
is bugref_to_href('boo#9876'),                                            '<a href="https://bugzilla.opensuse.org/show_bug.cgi?id=9876">boo#9876</a>';
is href_to_bugref('https://github.com/foo/bar/issues/1234'),              'gh#foo/bar#1234';
is href_to_bugref('https://github.com/os-autoinst/os-autoinst/pull/960'), 'gh#os-autoinst/os-autoinst#960', 'github pull are also transformed same as issues';
is bugref_to_href('gh#foo/bar#1234'),                                     '<a href="https://github.com/foo/bar/issues/1234">gh#foo/bar#1234</a>';
like bugref_to_href('bsc#2345 poo#3456 and more'),                        qr{a href="https://bugzilla.suse.com/show_bug.cgi\?id=2345">bsc\#2345</a> <a href=.*3456.*> and more}, 'bugrefs in text get replaced';
like bugref_to_href('boo#2345,poo#3456'),                                 qr{a href="https://bugzilla.opensuse.org/show_bug.cgi\?id=2345">boo\#2345</a>,<a href=.*3456.*}, 'interpunctation is not consumed by href';

done_testing();
