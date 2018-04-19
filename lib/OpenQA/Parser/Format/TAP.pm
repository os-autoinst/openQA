# Copyright (C) 2018 SUSE LLC
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

package OpenQA::Parser::Format::TAP;
# Translates to TAP -> openQA internal
use Mojo::Base 'OpenQA::Parser::Format::Base';
use Carp qw(croak confess);
use OpenQA::Parser::Result::OpenQA;
use TAP::Parser;

has include_results => 0;
has [qw(_tap)];

# Override to use specific OpenQA Result class.
sub _add_single_result { shift->generated_tests_results->add(OpenQA::Parser::Result::OpenQA->new(@_)) }
sub _add_result {
    my $self = shift;
    my %opts = ref $_[0] eq 'HASH' ? %{$_[0]} : @_;
    return $self->_add_single_result(@_) unless $self->include_results && $opts{name};

    my $name = $opts{name};
    my $tests = $self->generated_tests->search('name', qr/$name/);

    if ($tests->size == 1) {
        $self->_add_single_result(@_, test => $tests->first);
    }
    else {
        $self->_add_single_result(@_);
    }

    return $self->generated_tests_results;
}

sub parse {
    my ($self, $TAP) = @_;
    confess "No TAP given/loaded" unless $TAP;
    my $tap = TAP::Parser->new({ tap => $TAP });
    confess "Failed ".$tap->parse_errors if $tap->parse_errors ;

    while (my $res = $tap->next) {
        my $result =  $res;
        next if $result->type ne 'test';
        my $t_name = $res->{description};
        # Only because it happened also for LTP
        $t_name =~ s/:/_/g;

        $result->{result} = 'ok';
        $result->{result} = 'fail' unless $result->is_actual_ok;
        $result->{name} = $t_name;

        # stick for now to only test results.
        my $details
          = {result => ($result->is_actual_ok)? 'ok' : 'fail'};

        $details->{text}  = $res->as_string;
        $details->{title} = $t_name;

        push @{$result->{details}}, $details;

        $self->_add_output(
            {
                file    => "TAP-$t_name.txt",
                content => $res->raw
            });

        #        my $t = OpenQA::Parser::Result::LTP::SubTest->new(
        #    flags    => {},
        #    category => 'LTP',
        #    name     => $t_name,
        #    log      => $res->{test}->{log},
        #    duration => $res->{test}->{duration},
        #    script   => undef,
        #    result   => $res->{test}->{result});
        #$self->tests->add($t);
        #$result->{test} = $t if $self->include_results();
        $self->_add_single_result($result);
    }

    $self;
}

=encoding utf-8

=head1 NAME

OpenQA::Parser::Format::TAP - TAP file parser

=head1 SYNOPSIS

    use OpenQA::Parser::Format::JUnit;

    my $parser = OpenQA::Parser::Format::JUnit->new()->load('file.xml');

    # Alternative interface
    use OpenQA::Parser qw(parser p);

    my $parser = p('JUnit')->include_result(1)->load('file.xml');

    my $parser = parser( JUnit => 'file.xml' );

    my $result_collection = $parser->results();
    my $test_collection   = $parser->tests();
    my $output_collection = $parser->output();

    my $arrayref = $result_collection->to_array;

    $parser->results->remove(0);

    my $passed_results = $parser->results->search( result => qr/ok/ );
    my $size = $passed_results->size;


=head1 DESCRIPTION

OpenQA::Parser::Format::JUnit is the parser for junit file format.
The parser is making use of the C<tests()>, C<results()> and C<output()> collections.

With the attribute C<include_result()> set to true, it will include inside the
results the respective test that generated it (inside the C<test()> attribute).
See also L<OpenQA::Parser::Result::OpenQA>.

=head1 ATTRIBUTES

OpenQA::Parser::Format::JUnit inherits all attributes from L<OpenQA::Parser::Format::Base>.

=head1 METHODS

OpenQA::Parser::Format::Base inherits all methods from L<OpenQA::Parser::Format::Base>, it only overrides
C<parse()> to generate a tree of results.

=cut

!!42;
