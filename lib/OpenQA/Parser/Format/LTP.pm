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

package OpenQA::Parser::Format::LTP;

# Translates to JSON LTP format -> LTP internal representation
# The parser results will be a collection of OpenQA::Parser::Result::LTP::Test
use Mojo::Base 'OpenQA::Parser::Format::JUnit';
use Carp qw(croak confess);
use Mojo::JSON 'decode_json';
use Storable 'dclone';
has include_results => 1;

sub _add_single_result { shift->results->add(OpenQA::Parser::Result::LTP::Test->new(@_)) }

# Parser
sub parse {
    my ($self, $json) = @_;
    confess "No JSON given/loaded" unless $json;
    my $decoded_json = decode_json $json;

    # may be optional since format result_array:v2
    $self->generated_tests_extra->add(OpenQA::Parser::Result::LTP::Environment->new($decoded_json->{environment}))
      if $decoded_json->{environment};

    foreach my $res (@{$decoded_json->{results}}) {
        my $result = dclone $res;
        my $t_name = $res->{test_fqn};
        $t_name =~ s/:/_/g;

        $result->{result} = 'ok';
        $result->{result} = 'fail' if $result->{test}->{result} !~ /pass/i || $result->{status} !~ /pass/i;

        # may be optional since format result_array:v2
        $result->{environment} = OpenQA::Parser::Result::LTP::Environment->new($result->{environment})
          if $res->{environment};

        $result->{name} = $t_name;

        my $details
          = {result => ($result->{test}->{result} !~ /pass/i || $result->{status} !~ /pass/i) ? 'fail' : 'ok'};
        my $text_fn = "LTP-$t_name.txt";
        my $content = $res->{test}->{log};

        $details->{text}  = $text_fn;
        $details->{title} = $t_name;

        push @{$result->{details}}, $details;

        $self->_add_output(
            {
                file    => $text_fn,
                content => $content
            });

        my $t = OpenQA::Parser::Result::LTP::SubTest->new(
            flags    => {},
            category => 'LTP',
            name     => $t_name,
            log      => $res->{test}->{log},
            duration => $res->{test}->{duration},
            script   => undef,
            result   => $res->{test}->{result});
        $self->tests->add($t);
        $result->{test} = $t if $self->include_results();
        $self->_add_single_result($result);
    }

    $self;
}

# Schema
{
    package OpenQA::Parser::Result::LTP::Test;
    use Mojo::Base 'OpenQA::Parser::Result::OpenQA';

    has environment => sub { OpenQA::Parser::Result::LTP::Environment->new() };
    has test        => sub { OpenQA::Parser::Result::LTP::SubTest->new() };
    has [qw(status test_fqn)];
}

# Additional data structure - they get mapped automatically
{
    package OpenQA::Parser::Result::LTP::SubTest;
    use Mojo::Base 'OpenQA::Parser::Result::Test';

    has [qw(log duration result)];
}

{
    package OpenQA::Parser::Result::LTP::Environment;
    use Mojo::Base 'OpenQA::Parser::Result';

    has [qw(gcc product revision kernel ltp_version harness libc arch)];
}

!!42;
