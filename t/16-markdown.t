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

use Mojo::Base -strict;

use Test::More;
use OpenQA::Markdown 'markdown_to_html';

subtest 'standard markdown' => sub {
    is markdown_to_html('Test'),                        "<p>Test</p>\n",                               'HTML rendered';
    is markdown_to_html("Test\n123\n\n456 789 tset\n"), qq{<p>Test\n123</p>\n\n<p>456 789 tset</p>\n}, 'HTML rendered';
    is markdown_to_html('*Test*'),                      "<p><em>Test</em></p>\n",                      'HTML rendered';
    is markdown_to_html('[Test](http://test.com)'), qq{<p><a href="http://test.com">Test</a></p>\n}, 'HTML rendered';
};

subtest 'bugrefs' => sub {
    is markdown_to_html('boo#123'),
      qq{<p><a href="https://bugzilla.opensuse.org/show_bug.cgi?id=123">boo#123</a></p>\n}, 'bugref expanded';
};

subtest 'openQA additions' => sub {
    is markdown_to_html('https://example.com'),
      qq{<p><a href="https://example.com">https://example.com</a></p>\n}, 'URL turned into a link';
    is markdown_to_html('t#123'), qq{<p><a href="/tests/123">t#123</a></p>\n}, 'testref expanded';
};

done_testing;
