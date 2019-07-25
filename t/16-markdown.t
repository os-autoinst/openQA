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
    is markdown_to_html('Test'),                        '<p>Test</p>',                               'HTML rendered';
    is markdown_to_html('# Test'),                      '<h1>Test</h1>',                             'HTML rendered';
    is markdown_to_html('## Test'),                     '<h2>Test</h2>',                             'HTML rendered';
    is markdown_to_html('### Test'),                    '<h3>Test</h3>',                             'HTML rendered';
    is markdown_to_html('#### Test'),                   '<h4>Test</h4>',                             'HTML rendered';
    is markdown_to_html('##### Test'),                  '<h5>Test</h5>',                             'HTML rendered';
    is markdown_to_html('###### Test'),                 '<h6>Test</h6>',                             'HTML rendered';
    is markdown_to_html("Test\n123\n\n456 789 tset\n"), qq{<p>Test\n123</p>\n\n<p>456 789 tset</p>}, 'HTML rendered';
    is markdown_to_html('*Test*'),                      '<p><em>Test</em></p>',                      'HTML rendered';
    is markdown_to_html('**Test**'),                    '<p><strong>Test</strong></p>',              'HTML rendered';
    is markdown_to_html("1. a\n2. b\n3. c\n"), qq{<ol>\n<li>a</li>\n<li>b</li>\n<li>c</li>\n</ol>}, 'HTML rendered';
    is markdown_to_html("* a\n* b\n* c\n"),    qq{<ul>\n<li>a</li>\n<li>b</li>\n<li>c</li>\n</ul>}, 'HTML rendered';
    is markdown_to_html('[Test](http://test.com)'),  qq{<p><a href="http://test.com">Test</a></p>},     'HTML rendered';
    is markdown_to_html('[Test](/test.html)'),       qq{<p><a href="/test.html">Test</a></p>},          'HTML rendered';
    is markdown_to_html('![Test](http://test.com)'), qq{<p><img src="http://test.com" alt="Test"></p>}, 'HTML rendered';
    is markdown_to_html('Test `123` 123'),           '<p>Test <code>123</code> 123</p>',                'HTML rendered';
    is markdown_to_html("> test\n> 123"), "<blockquote>\n  <p>test\n  123</p>\n</blockquote>", 'HTML rendered';
    is markdown_to_html('---'), '<hr>', 'HTML rendered';
};

subtest 'bugrefs' => sub {
    is markdown_to_html('boo#123'),
      qq{<p><a href="https://bugzilla.opensuse.org/show_bug.cgi?id=123">boo#123</a></p>}, 'bugref expanded';
    is markdown_to_html('testing boo#123 123'),
      qq{<p>testing <a href="https://bugzilla.opensuse.org/show_bug.cgi?id=123">boo#123</a> 123</p>},
      'bugref expanded';
    is markdown_to_html('testing boo#123 123 boo#321'),
      qq{<p>testing <a href="https://bugzilla.opensuse.org/show_bug.cgi?id=123">boo#123</a> 123}
      . qq{ <a href="https://bugzilla.opensuse.org/show_bug.cgi?id=321">boo#321</a></p>},
      'bugref expanded';
    is markdown_to_html("testing boo#123 \n123\n boo#321"),
      qq{<p>testing <a href="https://bugzilla.opensuse.org/show_bug.cgi?id=123">boo#123</a> \n123\n}
      . qq{ <a href="https://bugzilla.opensuse.org/show_bug.cgi?id=321">boo#321</a></p>},
      'bugref expanded';
    is markdown_to_html("boo\ntesting boo#123 123\n123"),
      qq{<p>boo\ntesting <a href="https://bugzilla.opensuse.org/show_bug.cgi?id=123">boo#123</a> 123\n123</p>},
      'bugref expanded';
};

subtest 'openQA additions' => sub {
    is markdown_to_html('https://example.com'),
      qq{<p><a href="https://example.com">https://example.com</a></p>}, 'URL turned into a link';
    is markdown_to_html('testing https://example.com 123'),
      qq{<p>testing <a href="https://example.com">https://example.com</a> 123</p>}, 'URL turned into a link';
    is markdown_to_html("t\ntesting https://example.com 123\n123"),
      qq{<p>t\ntesting <a href="https://example.com">https://example.com</a> 123\n123</p>}, 'URL turned into a link';
    is markdown_to_html('t#123'),             qq{<p><a href="/tests/123">t#123</a></p>},             'testref expanded';
    is markdown_to_html('testing t#123 123'), qq{<p>testing <a href="/tests/123">t#123</a> 123</p>}, 'testref expanded';
    is markdown_to_html("t\ntesting t#123 123\n123"), qq{<p>t\ntesting <a href="/tests/123">t#123</a> 123\n123</p>},
      'testref expanded';
};

subtest 'unsafe HTML filtered out' => sub {
    is markdown_to_html('Test <script>alert("boom!");</script> 123'), '<p>Test  123</p>', 'unsafe HTML filtered';
    is markdown_to_html('<font>Test</font>'),                         '<p>Test</p>',      'unsafe HTML filtered';
    is markdown_to_html('Test [Boom!](javascript:alert("boom!")) 123'), '<p>Test <a>Boom!</a> 123</p>',
      'unsafe HTML filtered';
    is markdown_to_html('<a href="/" onclick="someFunction()">Totally safe</a>'),
      '<p><a href="/">Totally safe</a></p>', 'unsafe HTML filtered';
    is markdown_to_html(qq{> hello <a name="n"\n> href="javascript:alert('boom!')">*you*</a>}),
      qq{<blockquote>\n  <p>hello <a><em>you</em></a></p>\n</blockquote>}, 'unsafe HTML filtered';
};

done_testing;
