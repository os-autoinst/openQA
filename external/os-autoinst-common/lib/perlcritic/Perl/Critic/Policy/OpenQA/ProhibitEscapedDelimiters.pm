# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package Perl::Critic::Policy::OpenQA::ProhibitEscapedDelimiters;

use strict;
use warnings;
use experimental 'signatures';
use base 'Perl::Critic::Policy';

use Perl::Critic::Utils qw( :severities :classification :ppi );

our $VERSION = '0.0.1';

sub default_severity { return $SEVERITY_MEDIUM }
sub default_themes { return qw(openqa) }
sub applies_to { return qw(PPI::Token::Quote::Double) }

sub violates ($self, $elem, $document) {
    my $content = $elem->content;
    return () unless $content =~ m/\\"/ || $content =~ m/\\\$/ || $content =~ m/\\@/;
    my $desc = 'Double-quoted string contains unnecessary backslash-escaped characters';
    my $expl = 'Use the q{} or qq{} operators instead of escaping characters to improve readability';
    return $self->violation($desc, $expl, $elem);
}

1;
