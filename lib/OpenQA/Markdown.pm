# Copyright 2019 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later
package OpenQA::Markdown;
use Mojo::Base -strict, -signatures;
use Mojo::Util 'xml_escape';
use OpenQA::App;

use Exporter 'import';
use Regexp::Common 'URI';
use OpenQA::Utils qw(BUGREF_REGEX UNCONSTRAINED_BUGREF_REGEX LABEL_REGEX FLAG_REGEX);
use OpenQA::Constants qw(FRAGMENT_REGEX);
use CommonMark;

our @EXPORT_OK = qw(bugref_to_html is_light_color markdown_to_html);

sub is_light_color {
    my $color = shift;
    return undef unless $color =~ m/^#([a-fA-F0-9]{2})([a-fA-F0-9]{2})([a-fA-F0-9]{2})$/;
    my ($red, $green, $blue) = ($1, $2, $3);
    my $sum = hex($red) + hex($green) + hex($blue);
    return $sum > 380;
}

sub bugref_to_html ($bugref, $fancy = 0) {
    my $app = OpenQA::App->singleton;
    my $bugs = $app->schema->resultset('Bugs');
    my $bug = $bugs->get_bug($bugref);
    my $bugurl = $app->bugurl_for($bugref);
    my $bugtitle = xml_escape($app->bugtitle_for($bugref, $bug));
    my $bugicon = $app->bugicon_for($bugref, $bug);
    return
qq{<span title="$bugtitle" class="openqa-bugref"><a href="$bugurl"><i class="test-label $bugicon"></i>&nbsp;$bugref</a></span>}
      if ($fancy);
    return qq{<a href="$bugurl" title="$bugtitle">$bugref</a>};
}

sub _label_to_html ($label_text) {
    $label_text =~ s/${\UNCONSTRAINED_BUGREF_REGEX}/bugref_to_html($+{match})/ge;
    return "<span class=\"openqa-label\">label:$label_text<\/span>";
}

sub _flag_to_html ($flag_text) {
    return "<span class=\"openqa-flag\">flag:$flag_text<\/span>";
}

sub markdown_to_html ($text) {
    # Turn all URLs into links
    $text =~ s/(?<!['"(<>])($RE{URI}${\FRAGMENT_REGEX})/<$1>/gio;

    # Turn references to test modules and needling steps into links
    $text =~ s!\b(t#([\w/]+))![$1](/tests/$2)!gi;

    my $html = CommonMark->markdown_to_html($text);

    # Turn all bugrefs into fancy bugref links
    $html =~ s/${\BUGREF_REGEX}/bugref_to_html($+{match}, 1)/geio;

    # Highlight labels
    $html =~ s/${\LABEL_REGEX}/_label_to_html($+{match})/ge;

    # Highlight flags (e.g. carryover)
    $html =~ s/${\FLAG_REGEX}/_flag_to_html($+{match})/ge;

    # Custom markup "{{color:#ff0000|Some text}}"
    $html =~ s/(\{\{([^|]+?)\|(.*?)\}\})/_custom($1, $2, $3)/ge;

    return $html;
}

sub _custom ($full, $rules, $text) {
    if ($rules =~ /^color:(#[a-fA-F0-9]{6})$/) {
        my $color = $1;
        my $bg = is_light_color($color) ? 'black' : 'white';
        return qq{<span style="color:$color;background-color:$bg">$text</span>};
    }
    return $full;
}

1;
