#!/usr/bin/env perl
# Copyright (c) 2013 SUSE Linux Products GmbH
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

=head1 failed_needles

failed_needles.pl - display information about failed needles

=head1 SYNOPSIS

failed_needles.pl [OPTIONS] FILTER...

=head1 OPTIONS

=over 4

=item B<--help, -h>

print help

=item B<--pattern> PATTERN

restrict to test results matching PATTERN

=item B<--ordering> <byneedle|byname>

byneedle: needle name is the index. filter applies to needle name
byname: test name is the index. filter applies to test name

=item B<FILTER

only output results with that index match (see --ordering)

=back

=head1 DESCRIPTION

by default informations about all test results are printed

=head1 EXAMPLES

$ failed_needles.pl --pattern openSUSE-Factory-NET-x86_64-Build0670*

$ failed_needles.pl zypper_in-1-131M2

=cut

use strict;
use warnings;
use Data::Dump;
use Getopt::Long;
use JSON;
Getopt::Long::Configure("no_ignore_case");

use FindBin;
use lib "/usr/share/openqa/cgi-bin/modules/";
use openqa qw/get_failed_needles/;

my %options ;

sub usage($) {
	my $r = shift;
	eval "use Pod::Usage; pod2usage($r);";
	if ($@) {
		die "cannot display help, install perl(Pod::Usage)\n";
	}
}

GetOptions(
	\%options,
	"pattern=s",
	"ordering=s",
	"fatal",
	"verbose|v",
	"help|h",
) or usage(1);

usage(0) if $options{help};

$options{ordering} ||= 'byneedle';
my $failures = get_failed_needles(%options);

if (@ARGV) {
	my %x = map { $_ => $failures->{$_} } @ARGV;
	$failures = \%x;
}

dd $failures;

1;
# vim: set ts=4 sw=4 sts=4 et:
