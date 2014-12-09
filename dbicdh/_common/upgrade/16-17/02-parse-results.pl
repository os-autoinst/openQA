# Copyright (C) 2014 SUSE Linux Products GmbH
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

#!perl

use strict;
use warnings;

use openqa;

use Data::Dump qw(dd pp);

sub insert_tm($$$) {
  my ($schema, $job, $tm) = @_;
  $tm->{details} = []; # ignore
  #print pp($job) . " " . pp($tm) . "\n";
  my $r = $schema->resultset("JobModules")->find_or_new(
    {
      job_id => $job->{id},
      script => $tm->{script}
    },
  );
  if (!$r->in_storage) {
    $r->category($tm->{category});
    $r->name($tm->{name});
    $r->insert;
  }
  my $result = $tm->{result};
  $result =~ s,fail,failed,;
  $result =~ s,^na,none,;
  $result =~ s,^ok,passed,;
  $result =~ s,^skip,skipped,;
  my $rid = $schema->resultset("JobResults")->search({ name => $result })->single || die "can't find $result";
  $r->update({ result_id => $rid->id });
}

sub {
  my $schema = shift;

  my @jobs = $schema->resultset('Jobs')->all();
  for my $job (@jobs) {
    $job = $job->to_hash();
    my $testdirname = $job->{settings}->{NAME};
    my $results = test_result($testdirname);
    next unless $results; # broken test
    #print $testdirname . " - " . ref($results->{testmodules}) . "\n";
    for my $tm (@{$results->{testmodules}}) {
      insert_tm($schema, $job, $tm);
      #return;
    }
  }

}

