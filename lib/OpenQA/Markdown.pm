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

require Text::Markdown;
our @ISA = qw(Text::Markdown);

use Exporter 'import';
use Regexp::Common 'URI';
use OpenQA::Utils 'bugref_to_href';

our @EXPORT_OK = qw(markdown_to_html);

sub markdown_to_html {
    my $text = shift;
    my $m    = __PACKAGE__->new;
    my $html = $m->markdown($text);
    return $html;
}

# TODO: Kill it with fire
sub _DoAutoLinks {
    my ($self, $text) = @_;

    # auto-replace bugrefs with 'a href...'
    $text = bugref_to_href($text);

    # auto-replace every http(s) reference which is not already either html
    # 'a href...' or markdown link '[link](url)' or enclosed by Text::Markdown
    # URL markers '<>'
    $text =~ s@(?<!['"(<>])($RE{URI})@<$1>@gi;

    # For tests make sure that references into test modules and needling steps also work
    $text =~ s{\b(t#([\w/]+))}{<a href="/tests/$2">$1</a>}gi;

    return $self->SUPER::_DoAutoLinks($text);
}

1;
