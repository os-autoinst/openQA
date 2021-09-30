#!/usr/bin/env perl
# Copyright 2019-2020 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;

use FindBin;
use lib "$FindBin::Bin/lib", "$FindBin::Bin/../external/os-autoinst-common/lib";
use OpenQA::Test::TimeLimit '10';
use OpenQA::Markdown qw(bugref_to_markdown is_light_color markdown_to_html);

subtest 'standard markdown' => sub {
    is markdown_to_html('Test'), "<p>Test</p>\n", 'HTML rendered';
    is markdown_to_html('# Test #'), "<h1>Test</h1>\n", 'HTML rendered';
    is markdown_to_html('# Test'), "<h1>Test</h1>\n", 'HTML rendered';
    is markdown_to_html('## Test'), "<h2>Test</h2>\n", 'HTML rendered';
    is markdown_to_html('### Test'), "<h3>Test</h3>\n", 'HTML rendered';
    is markdown_to_html('#### Test'), "<h4>Test</h4>\n", 'HTML rendered';
    is markdown_to_html('##### Test'), "<h5>Test</h5>\n", 'HTML rendered';
    is markdown_to_html('###### Test'), "<h6>Test</h6>\n", 'HTML rendered';
    is markdown_to_html("Test\n123\n\n456 789 tset\n"), qq{<p>Test\n123</p>\n<p>456 789 tset</p>\n}, 'HTML rendered';
    is markdown_to_html('*Test*'), "<p><em>Test</em></p>\n", 'HTML rendered';
    is markdown_to_html('**Test**'), "<p><strong>Test</strong></p>\n", 'HTML rendered';
    is markdown_to_html("1. a\n2. b\n3. c\n"), qq{<ol>\n<li>a</li>\n<li>b</li>\n<li>c</li>\n</ol>\n}, 'HTML rendered';
    is markdown_to_html("* a\n* b\n* c\n"), qq{<ul>\n<li>a</li>\n<li>b</li>\n<li>c</li>\n</ul>\n}, 'HTML rendered';
    is markdown_to_html('[Test](http://test.com)'), qq{<p><a href="http://test.com">Test</a></p>\n}, 'HTML rendered';
    is markdown_to_html('[Test](/test.html)'), qq{<p><a href="/test.html">Test</a></p>\n}, 'HTML rendered';
    is markdown_to_html('![Test](http://test.com)'), qq{<p><img src="http://test.com" alt="Test" /></p>\n},
      'HTML rendered';
    is markdown_to_html('Test `123` 123'), "<p>Test <code>123</code> 123</p>\n", 'HTML rendered';
    is markdown_to_html("> test\n> 123"), "<blockquote>\n<p>test\n123</p>\n</blockquote>\n", 'HTML rendered';
    is markdown_to_html('---'), "<hr />\n", 'HTML rendered';
};

subtest 'bugrefs' => sub {
    is markdown_to_html('boo#123'),
      qq{<p><a href="https://bugzilla.opensuse.org/show_bug.cgi?id=123">boo#123</a></p>\n}, 'bugref expanded';
    is markdown_to_html('testing boo#123 123'),
      qq{<p>testing <a href="https://bugzilla.opensuse.org/show_bug.cgi?id=123">boo#123</a> 123</p>\n},
      'bugref expanded';
    is markdown_to_html('testing boo#123 123 boo#321'),
      qq{<p>testing <a href="https://bugzilla.opensuse.org/show_bug.cgi?id=123">boo#123</a> 123}
      . qq{ <a href="https://bugzilla.opensuse.org/show_bug.cgi?id=321">boo#321</a></p>\n},
      'bugref expanded';
    is markdown_to_html("testing boo#123\n123\n boo#321"),
      qq{<p>testing <a href="https://bugzilla.opensuse.org/show_bug.cgi?id=123">boo#123</a>\n123\n}
      . qq{<a href="https://bugzilla.opensuse.org/show_bug.cgi?id=321">boo#321</a></p>\n},
      'bugref expanded';
    is markdown_to_html("boo\ntesting boo#123 123\n123"),
      qq{<p>boo\ntesting <a href="https://bugzilla.opensuse.org/show_bug.cgi?id=123">boo#123</a> 123\n123</p>\n},
      'bugref expanded';
};

subtest 'openQA additions' => sub {
    is markdown_to_html('https://example.com'),
      qq{<p><a href="https://example.com">https://example.com</a></p>\n}, 'URL turned into a link';
    is markdown_to_html('https://example.com/#fragment_-'),
      qq{<p><a href="https://example.com/#fragment_-">https://example.com/#fragment_-</a></p>\n},
      'URL with fragment turned into a link';
    is markdown_to_html('https://example.com/#fragment/<script>test</script>'),
qq{<p><a href="https://example.com/#fragment/">https://example.com/#fragment/</a><!-- raw HTML omitted -->test<!-- raw HTML omitted --></p>\n},
      'URL with fragment + script turned into a link';
    is markdown_to_html('https://example.com/#?(.-/\' some text'),
      qq{<p><a href="https://example.com/#?(.-/&#x27;">https://example.com/#?(.-/'</a> some text</p>\n},
      'URL w fragment + special characters turned into a link';

    is markdown_to_html('testing https://example.com 123'),
      qq{<p>testing <a href="https://example.com">https://example.com</a> 123</p>\n}, 'URL turned into a link';
    is markdown_to_html("t\ntesting https://example.com 123\n123"),
      qq{<p>t\ntesting <a href="https://example.com">https://example.com</a> 123\n123</p>\n}, 'URL turned into a link';

    is markdown_to_html('t#123'), qq{<p><a href="/tests/123">t#123</a></p>\n}, 'testref expanded';
    is markdown_to_html('testing t#123 123'), qq{<p>testing <a href="/tests/123">t#123</a> 123</p>\n},
      'testref expanded';
    is markdown_to_html("t\ntesting t#123 123\n123"), qq{<p>t\ntesting <a href="/tests/123">t#123</a> 123\n123</p>\n},
      'testref expanded';

    is markdown_to_html(qq{{{color:#ffffff|"Text"}}}),
      qq{<p><span style="color:#ffffff;background-color:black">&quot;Text&quot;</span></p>\n},
      'White text';
    is markdown_to_html("test {{color:#ff0000|Text}} 123"),
      qq{<p>test <span style="color:#ff0000;background-color:white">Text</span> 123</p>\n}, 'Red text';
    is markdown_to_html("test {{color:#FFFFFF|Text}} 123"),
      qq{<p>test <span style="color:#FFFFFF;background-color:black">Text</span> 123</p>\n}, 'White text';
    is markdown_to_html("test {{color:#00ff00|Some Text}} 123"),
      qq{<p>test <span style="color:#00ff00;background-color:white">Some Text</span> 123</p>\n}, 'Green text';
    is markdown_to_html("test {{color:#00ff00|Some Text}} 123 {{color:#0000ff|Also {w}orks}}"),
      qq{<p>test <span style="color:#00ff00;background-color:white">Some Text</span> 123}
      . qq{ <span style="color:#0000ff;background-color:white">Also {w}orks</span></p>\n},
      'Green and blue text';
    is markdown_to_html("test {{  color: #00ff00  |  Some Text  }} 123"),
      "<p>test {{  color: #00ff00  |  Some Text  }} 123</p>\n", 'Extra whitespace is not allowed';
    is markdown_to_html("test {{color:javascript|Text}} 123"),
      qq{<p>test {{color:javascript|Text}} 123</p>\n}, 'Invalid custom tag';
    is markdown_to_html(qq{test {{javascript:alert("test")|Text}} 123}),
      qq{<p>test {{javascript:alert(&quot;test&quot;)|Text}} 123</p>\n}, 'Invalid custom tag';
};

subtest 'unsafe HTML filtered out' => sub {
    is markdown_to_html('Test <script>alert("boom!");</script> 123'),
      "<p>Test <!-- raw HTML omitted -->alert(&quot;boom!&quot;);<!-- raw HTML omitted --> 123</p>\n",
      'unsafe HTML filtered';
    is markdown_to_html('<font>Test</font>'), "<p><!-- raw HTML omitted -->Test<!-- raw HTML omitted --></p>\n",
      'unsafe HTML filtered';
    is markdown_to_html('Test [Boom!](javascript:alert("boom!")) 123'), qq{<p>Test <a href="">Boom!</a> 123</p>\n},
      'unsafe HTML filtered';
    is markdown_to_html('<a href="/" onclick="someFunction()">Totally safe</a>'),
      "<p><!-- raw HTML omitted -->Totally safe<!-- raw HTML omitted --></p>\n", 'unsafe HTML filtered';
    is markdown_to_html(qq{> hello <a name="n"\n> href="javascript:alert('boom!')">*you*</a>}),
      qq{<blockquote>\n<p>hello <!-- raw HTML omitted --><em>you</em><!-- raw HTML omitted --></p>\n</blockquote>\n},
      'unsafe HTML filtered';
    is markdown_to_html('{{color:#0000ff|<a>Test</a>}}'),
      qq{<p><span style="color:#0000ff;background-color:white">}
      . qq{<!-- raw HTML omitted -->Test<!-- raw HTML omitted --></span></p>\n},
      'unsafe HTML filtered';
};

subtest 'bugrefs to markdown' => sub {
    is bugref_to_markdown('bnc#9876'), '[bnc#9876](https://bugzilla.suse.com/show_bug.cgi?id=9876)', 'right markdown';
    is bugref_to_markdown('bsc#9876'), '[bsc#9876](https://bugzilla.suse.com/show_bug.cgi?id=9876)', 'right markdown';
    is bugref_to_markdown('boo#9876'), '[boo#9876](https://bugzilla.opensuse.org/show_bug.cgi?id=9876)',
      'right markdown';
    is bugref_to_markdown('bgo#9876'), '[bgo#9876](https://bugzilla.gnome.org/show_bug.cgi?id=9876)', 'right markdown';
    is bugref_to_markdown('brc#9876'), '[brc#9876](https://bugzilla.redhat.com/show_bug.cgi?id=9876)', 'right markdown';
    is bugref_to_markdown('bko#9876'), '[bko#9876](https://bugzilla.kernel.org/show_bug.cgi?id=9876)', 'right markdown';
    is bugref_to_markdown('poo#9876'), '[poo#9876](https://progress.opensuse.org/issues/9876)', 'right markdown';
    is bugref_to_markdown('gh#foo/bar#1234'), '[gh#foo/bar#1234](https://github.com/foo/bar/issues/1234)',
      'right markdown';
    is bugref_to_markdown('kde#9876'), '[kde#9876](https://bugs.kde.org/show_bug.cgi?id=9876)', 'right markdown';
    is bugref_to_markdown('fdo#9876'), '[fdo#9876](https://bugs.freedesktop.org/show_bug.cgi?id=9876)',
      'right markdown';
    is bugref_to_markdown('jsc#9876'), '[jsc#9876](https://jira.suse.de/browse/9876)', 'right markdown';
    is bugref_to_markdown("boo#9876\n\ntest boo#211\n"),
      "[boo#9876](https://bugzilla.opensuse.org/show_bug.cgi?id=9876)\n\n"
      . "test [boo#211](https://bugzilla.opensuse.org/show_bug.cgi?id=211)\n",
      'right markdown';
};

subtest 'color detection' => sub {
    ok !is_light_color('#000000'), 'dark';
    ok !is_light_color('#ff0000'), 'dark';
    ok !is_light_color('#00ff00'), 'dark';
    ok !is_light_color('#0000ff'), 'dark';
    ok !is_light_color('#0000FF'), 'dark';
    ok is_light_color('#ffffff'), 'light';
    ok is_light_color('#FFFFFF'), 'light';
    ok !is_light_color('test'), 'not a color at all';
};

done_testing;
