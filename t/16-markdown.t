#!/usr/bin/env perl
# Copyright 2019-2020 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;
use Test::Mojo;
use Test::Warnings ':report_warnings';

use FindBin;
use lib "$FindBin::Bin/lib", "$FindBin::Bin/../external/os-autoinst-common/lib";
use OpenQA::Test::Case;
use OpenQA::Test::TimeLimit '10';
use OpenQA::Markdown qw(bugref_to_html is_light_color markdown_to_html);

my $test_case = OpenQA::Test::Case->new;
my $schema = $test_case->init_data();
my $t = Test::Mojo->new('OpenQA::WebAPI');

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
qq{<p><span title="Bug referenced: boo#123" class="openqa-bugref"><a href="https://bugzilla.opensuse.org/show_bug.cgi?id=123"><i class="test-label label_bug fa fa-bug"></i>&nbsp;boo#123</a></span></p>\n},
      'bugref expanded';
    is markdown_to_html('testing boo#123 123'),
qq{<p>testing <span title="Bug referenced: boo#123" class="openqa-bugref"><a href="https://bugzilla.opensuse.org/show_bug.cgi?id=123"><i class="test-label label_bug fa fa-bug"></i>&nbsp;boo#123</a></span> 123</p>\n},
      'bugref expanded';
    is markdown_to_html('testing boo#123 123 boo#321'),
qq{<p>testing <span title="Bug referenced: boo#123" class="openqa-bugref"><a href="https://bugzilla.opensuse.org/show_bug.cgi?id=123"><i class="test-label label_bug fa fa-bug"></i>&nbsp;boo#123</a></span> 123}
      . qq{ <span title="Bug referenced: boo#321" class="openqa-bugref"><a href="https://bugzilla.opensuse.org/show_bug.cgi?id=321"><i class="test-label label_bug fa fa-bug"></i>&nbsp;boo#321</a></span></p>\n},
      'bugref expanded';
    is markdown_to_html("testing boo#123\n123\n boo#321"),
qq{<p>testing <span title="Bug referenced: boo#123" class="openqa-bugref"><a href="https://bugzilla.opensuse.org/show_bug.cgi?id=123"><i class="test-label label_bug fa fa-bug"></i>&nbsp;boo#123</a></span>\n123\n}
      . qq{<span title="Bug referenced: boo#321" class="openqa-bugref"><a href="https://bugzilla.opensuse.org/show_bug.cgi?id=321"><i class="test-label label_bug fa fa-bug"></i>&nbsp;boo#321</a></span></p>\n},
      'bugref expanded';
    is markdown_to_html("boo\ntesting boo#123 123\n123"),
qq{<p>boo\ntesting <span title="Bug referenced: boo#123" class="openqa-bugref"><a href="https://bugzilla.opensuse.org/show_bug.cgi?id=123"><i class="test-label label_bug fa fa-bug"></i>&nbsp;boo#123</a></span> 123\n123</p>\n},
      'bugref expanded';
    is markdown_to_html('related issues: boo#123,bsc#1234'),
qq{<p>related issues: <span title="Bug referenced: boo#123" class="openqa-bugref"><a href="https://bugzilla.opensuse.org/show_bug.cgi?id=123"><i class="test-label label_bug fa fa-bug"></i>&nbsp;boo#123</a></span>,}
      . qq{<span title="Bug referenced: bsc#1234" class="openqa-bugref"><a href="https://bugzilla.suse.com/show_bug.cgi?id=1234"><i class="test-label label_bug fa fa-bug"></i>&nbsp;bsc#1234</a></span></p>\n},
      'bugref expanded';
    is markdown_to_html('related issue: bsc#1234, yada yada'),
qq{<p>related issue: <span title="Bug referenced: bsc#1234" class="openqa-bugref"><a href="https://bugzilla.suse.com/show_bug.cgi?id=1234"><i class="test-label label_bug fa fa-bug"></i>&nbsp;bsc#1234</a></span>, yada yada</p>\n},
      'bugref expanded';
    is markdown_to_html('label:force_result:passed:bsc#1234'),
      qq{<p><span class="openqa-label">label:force_result:passed:}
      . qq{<a href="https://bugzilla.suse.com/show_bug.cgi?id=1234" title="Bug referenced: bsc#1234">bsc#1234</a></span></p>\n},
      'bugref expaned within label';
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
    is bugref_to_html('bnc#9876'),
      '<a href="https://bugzilla.suse.com/show_bug.cgi?id=9876" title="Bug referenced: bnc#9876">bnc#9876</a>',
      'right markdown for bnc';
    is bugref_to_html('bsc#9876', 1),
'<span title="Bug referenced: bsc#9876" class="openqa-bugref"><a href="https://bugzilla.suse.com/show_bug.cgi?id=9876"><i class="test-label label_bug fa fa-bug"></i>&nbsp;bsc#9876</a></span>',
      'right markdown for bsc';
    is bugref_to_html('boo#9876'),
      '<a href="https://bugzilla.opensuse.org/show_bug.cgi?id=9876" title="Bug referenced: boo#9876">boo#9876</a>',
      'right markdown for boo';
    is bugref_to_html('bgo#9876'),
      '<a href="https://bugzilla.gnome.org/show_bug.cgi?id=9876" title="Bug referenced: bgo#9876">bgo#9876</a>',
      'right markdown for bgo';
    is bugref_to_html('brc#9876'),
      '<a href="https://bugzilla.redhat.com/show_bug.cgi?id=9876" title="Bug referenced: brc#9876">brc#9876</a>',
      'right markdownfor brc';
    is bugref_to_html('bko#9876'),
      '<a href="https://bugzilla.kernel.org/show_bug.cgi?id=9876" title="Bug referenced: bko#9876">bko#9876</a>',
      'right markdown for bko';
    is bugref_to_html('poo#9876'),
      '<a href="https://progress.opensuse.org/issues/9876" title="Bug referenced: poo#9876">poo#9876</a>',
      'right markdown for poo';
    is bugref_to_html('gh#foo/bar#1234'),
      '<a href="https://github.com/foo/bar/issues/1234" title="Bug referenced: gh#foo/bar#1234">gh#foo/bar#1234</a>',
      'right markdown for gh';
    is bugref_to_html('kde#9876'),
      '<a href="https://bugs.kde.org/show_bug.cgi?id=9876" title="Bug referenced: kde#9876">kde#9876</a>',
      'right markdown for kde';
    is bugref_to_html('fdo#9876'),
      '<a href="https://bugs.freedesktop.org/show_bug.cgi?id=9876" title="Bug referenced: fdo#9876">fdo#9876</a>',
      'right markdown for fdo';
    is bugref_to_html('jsc#9876'),
      '<a href="https://jira.suse.de/browse/9876" title="Bug referenced: jsc#9876">jsc#9876</a>',
      'right markdown for jsc';
    is bugref_to_html('pio#foo#1234'),
      '<a href="https://pagure.io/foo/issue/1234" title="Bug referenced: pio#foo#1234">pio#foo#1234</a>',
      'right markdown for pio';
    is bugref_to_html('pio#foo/bar#1234'),
      '<a href="https://pagure.io/foo/bar/issue/1234" title="Bug referenced: pio#foo/bar#1234">pio#foo/bar#1234</a>',
      'right markdownfor pio with slash';
    is bugref_to_html('ggo#GNOME/foo#1234'),
'<a href="https://gitlab.gnome.org/GNOME/foo/issues/1234" title="Bug referenced: ggo#GNOME/foo#1234">ggo#GNOME/foo#1234</a>',
      'right markdown for ggo';
    is bugref_to_html('gfs#flatpak/fedora-flatpaks#26'),
'<a href="https://gitlab.com/fedora/sigs/flatpak/fedora-flatpaks/issues/26" title="Bug referenced: gfs#flatpak/fedora-flatpaks#26">gfs#flatpak/fedora-flatpaks#26</a>',
      'right markdown for gfs';
    is markdown_to_html("boo#9876\n\ntest boo#211\n"),
qq{<p><span title="Bug referenced: boo#9876" class="openqa-bugref"><a href="https://bugzilla.opensuse.org/show_bug.cgi?id=9876"><i class="test-label label_bug fa fa-bug"></i>&nbsp;boo#9876</a></span></p>\n}
      . qq{<p>test <span title="Bug referenced: boo#211" class="openqa-bugref"><a href="https://bugzilla.opensuse.org/show_bug.cgi?id=211"><i class="test-label label_bug fa fa-bug"></i>&nbsp;boo#211</a></span></p>\n},
      'right markdown for 2x boo';
    is markdown_to_html('label:force_result:passed:bsc#1234'),
qq{<p><span class="openqa-label">label:force_result:passed:<a href="https://bugzilla.suse.com/show_bug.cgi?id=1234" title="Bug referenced: bsc#1234">bsc#1234</a></span></p>\n},
      'right markdown for label with bsc';
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
