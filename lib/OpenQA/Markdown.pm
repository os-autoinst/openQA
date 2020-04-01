# Copyright (C) 2019 SUSE LLC
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
use OpenQA::Utils qw(bugref_regex bugurl);
use CommonMark;

our @EXPORT_OK = qw(bugref_to_markdown is_light_color markdown_to_html);

my $RE = bugref_regex;

sub bugref_to_markdown {
    my $text = shift;
    $text =~ s/$RE/"[$+{match}](" . bugurl($+{match}) . ')'/geio;
    return $text;
}

sub is_light_color {
    my $color = shift;
    return undef unless $color =~ m/^#([a-fA-F0-9]{2})([a-fA-F0-9]{2})([a-fA-F0-9]{2})$/;
    my ($red, $green, $blue) = ($1, $2, $3);
    my $sum = hex($red) + hex($green) + hex($blue);
    return $sum > 380;
}

sub markdown_to_html {
    my $text = shift;

    $text = bugref_to_markdown($text);

    # Turn all remaining URLs into links
    $text =~ s/(?<!['"(<>])($RE{URI})/<$1>/gio;

    # Turn references to test modules and needling steps into links
    $text =~ s!\b(t#([\w/]+))![$1](/tests/$2)!gi;

    my $html = CommonMark->markdown_to_html($text);

    # Custom markup "{{color:#ff0000|Some text}}"
    $html =~ s/(\{\{([^|]+?)\|(.*?)\}\})/_custom($1, $2, $3)/ge;

    return $html;
}

sub _custom {
    my ($full, $rules, $text) = @_;
    if ($rules =~ /^color:(#[a-fA-F0-9]{6})$/) {
        my $color = $1;
        my $bg    = is_light_color($color) ? 'black' : 'white';
        return qq{<span style="color:$color;background-color:$bg">$text</span>};
    }
    return $full;
}

1;
