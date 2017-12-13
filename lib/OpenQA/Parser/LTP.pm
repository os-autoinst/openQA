# Copyright (C) 2017 SUSE LLC
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

package OpenQA::Parser::LTP;
# Translates to JSON LTP format -> LTP internal representation
# The parser results will be a collection of OpenQA::Parser::Result::LTP::Test
use Mojo::Base 'OpenQA::Parser';
use Carp qw(croak confess);
use Mojo::JSON 'decode_json';
use OpenQA::Parser::Result::LTP::Test;

sub parse {
    my ($self, $json) = @_;
    confess "No JSON given/loaded" unless $json;
    my $decoded_json = decode_json $json;

    # may be optional since format result_array:v2
    $self->generated_tests_extra->add(OpenQA::Parser::Result::LTP::Environment->new($decoded_json->{environment}))
      if $decoded_json->{environment};

    foreach my $res (@{$decoded_json->{results}}) {
        # may be optional since format result_array:v2
        $res->{environment} = OpenQA::Parser::Result::LTP::Environment->new($res->{environment}) if $res->{environment};
        $res->{test} = OpenQA::Parser::Result::LTP::SubTest->new($res->{test});
        $self->generated_tests_results->add(OpenQA::Parser::Result::LTP::Test->new($res));
    }

    $self;
}

!!42;
