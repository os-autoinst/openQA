# Copyright (C) 2019 SUSE Linux Products GmbH
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
# with this program; if not, see <http://www.gnu.org/licenses/>.
package OpenQA::Markdown;
use Mojo::Base -strict;

use Exporter 'import';
use Regexp::Common 'URI';
use OpenQA::Utils 'bugref_to_href';
use Text::Markdown;
use HTML::Restrict;

our @EXPORT_OK = qw(markdown_to_html);

# Limit tags to a safe subset
my $RULES = {
    a          => [qw(href)],
    blockquote => [],
    code       => [],
    em         => [],
    img        => [qw(src alt)],
    h1         => [],
    h2         => [],
    h3         => [],
    h4         => [],
    h5         => [],
    h6         => [],
    hr         => [],
    li         => [],
    ol         => [],
    p          => [],
    strong     => [],
    ul         => []};

# Only allow "href=/...", "href=http://..." and "href=https://..."
my $SCHEMES = [undef, 'http', 'https'];

my $RESTRICT = HTML::Restrict->new(rules => $RULES, uri_schemes => $SCHEMES);
my $MARKDOWN = Text::Markdown->new;

sub markdown_to_html {
    my $text = shift;

    # Replace bugrefs with links
    $text = bugref_to_href($text);

    # Turn all remaining URLs into links
    $text =~ s@(?<!['"(<>])($RE{URI})@<$1>@gi;

    # Turn references to test modules and needling steps into links
    $text =~ s{\b(t#([\w/]+))}{<a href="/tests/$2">$1</a>}gi;

    # Markdown -> HTML
    my $html = $MARKDOWN->markdown($text);

    # Unsafe -> safe
    return $RESTRICT->process($html);
}

1;
