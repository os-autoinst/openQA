# Copyright (C) 2020-2021 SUSE LLC
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

package OpenQA::Test::TimeLimit;
use Test::Most;

my $SCALE_FACTOR = 1;

sub import {
    my ($package, $limit) = @_;
    die "$package: Need argument on import, e.g. use: use OpenQA::Test::TimeLimit '42';" unless $limit;
    # disable timeout if requested by ENV variable or running within debugger
    return if ($ENV{OPENQA_TEST_TIMEOUT_DISABLE} or $INC{'perl5db.pl'});
    $SCALE_FACTOR *= $ENV{OPENQA_TEST_TIMEOUT_SCALE_COVER} // 3 if Devel::Cover->can('report');
    $SCALE_FACTOR *= $ENV{OPENQA_TEST_TIMEOUT_SCALE_CI}    // 2 if $ENV{CI};
    $limit        *= $SCALE_FACTOR;
    $SIG{ALRM} = sub { BAIL_OUT "test '$0' exceeds runtime limit of '$limit' seconds\n" };
    alarm $limit;
}

sub scale_timeout {
    return $_[0] * $SCALE_FACTOR;
}

1;

=encoding utf8

=head1 NAME

OpenQA::Test::TimeLimit - Limit test runtime

=head1 SYNOPSIS

  use OpenQA::Test::TimeLimit '42';

=head1 DESCRIPTION

This aborts a test if the specified runtime limit in seconds is
exceeded.

Example output for t/basic.t:

  t/basic.t .. run... failed: test exceeds runtime limit of '1' seconds

Example output for t/full-stack.t:

  ok 1 - assets are prefetched
  [info] [pid:4324] setting database search path to public when registering Minion plugin
  [info] Listening at "http://127.0.0.1:35182"
  Server available at http://127.0.0.1:35182
  Bailout called.  Further testing stopped:  get: Server returned error message test exceeds runtime limit of '6' seconds at /home/okurz/local/os-autoinst/openQA/t/lib/OpenQA/SeleniumTest.pm:107
  Bail out!  get: Server returned error message test exceeds runtime limit of '6' seconds at /home/okurz/local/os-autoinst/openQA/t/lib/OpenQA/SeleniumTest.pm:107
  FAILED--Further testing stopped: get: Server returned error message test exceeds runtime limit of '6' seconds at /home/okurz/local/os-autoinst/openQA/t/lib/OpenQA/SeleniumTest.pm:107

The timeout is scaled up when C<Devel::Cover> is active as well as when
running in a CI environment where the environment variable C<CI> is set. Both
scaling factors can be overridden with environment variables
C<OPENQA_TEST_TIMEOUT_SCALE_COVER> and C<OPENQA_TEST_TIMEOUT_SCALE_CI>
respectively.

=head2 Alternatives considered

* Just checking the runtime while not aborting the test – this idea has
not been followed as we want to prevent any external runners to run into
timeout first which can cause less obvious results
* https://metacpan.org/pod/Time::Limit - nice syntax that inspired me to
use a parameter on import but fails to completely stop tests including
all subprocesses
* https://metacpan.org/pod/Time::Out - applies a timeout to blocks, not
a complete module
* https://metacpan.org/pod/Time::SoFar - easy and simple but not
providing enough value to include
* https://metacpan.org/pod/Acme::Time::Baby - Just kidding ;)

=cut
