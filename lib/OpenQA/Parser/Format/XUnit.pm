# Copyright 2017-2018 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Parser::Format::XUnit;
use Mojo::Base 'OpenQA::Parser::Format::JUnit';

use Carp qw(croak confess);
use Mojo::DOM;

sub _add_single_result { shift->results->add(OpenQA::Parser::Result::XUnit->new(@_)) }

sub addproperty { shift->{properties}->add(OpenQA::Parser::Result::XUnit::Property->new(shift)) }

sub parse {
    my ($self, $xml) = @_;
    confess "No XML given/loaded" unless $xml;
    my $dom = Mojo::DOM->new->xml(1)->parse($xml);

    my @tests;
    my %t_names;
    my $i = 1;
    for my $ts ($dom->find('testsuite')->each) {

        my $result = {};
        my $ts_category = exists $ts->{classname} ? $ts->{classname} : 'xunit';
        my $ts_name = exists $ts->{name} ? $ts->{name} : 'unkn';

        # We add support for this optional field :)
        my $ts_generator_script = exists $ts->{script} ? $ts->{script} : undef;

        $result->{errors} = exists $ts->{errors} ? $ts->{errors} : undef;
        $result->{tests} = exists $ts->{tests} ? $ts->{tests} : undef;
        $result->{failures} = exists $ts->{failures} ? $ts->{failures} : undef;
        $result->{time} = exists $ts->{time} ? $ts->{time} : undef;


        $ts_category =~ s/[^A-Za-z0-9._-]/_/g;
        $ts_category =~ s/\..*$//;
        $ts_name =~ s/\..*$//;
        $ts_name =~ s/[^A-Za-z0-9._-]/_/g;
        $ts_name =~ s/^[^.]*\.//;
        $ts_name =~ s/\./_/;
        if (exists $ts->{id} && $ts->{id} =~ /^[0-9]+$/) {
            # make sure that the name is unique
            # prepend numeric $ts->{id}, start counting from 1
            $ts_name = ($ts->{id} + 1) . '_' . $ts_name;
        }
        $ts_name .= "_${i}" if $t_names{$ts_name};
        $t_names{$ts_name}++;
        $self->_add_test(
            {
                flags => {},
                category => $ts_category,
                name => $ts_name,
                script => $ts_generator_script,
            });

        my $ts_result = 'ok';
        $ts_result = 'fail' if ($ts->{failures} && $ts->{failures} > 0) || ($ts->{errors} && $ts->{errors} > 0);
        $result->{result} = $ts_result;
        $result->{dents} = 0;
        $result->{properties} = OpenQA::Parser::Results->new;
        my $num = 1;
        $ts->find('property')->each(sub { addproperty($result, {name => $_->{name}, value => $_->{value}}) });

        $ts->children('testcase')->each(
            sub {
                my $tc = shift;
                my $tc_result = 'ok';
                $tc_result = 'fail'
                  if ($tc->{failures} && $tc->{failures} > 0) || ($tc->{errors} && $tc->{errors} > 0);

                my $text_fn = "$ts_category-$ts_name-$num";
                $text_fn =~ s/[\/.]/_/g;
                $text_fn .= '.txt';
                my $content = "# Test messages ";
                $content .= "# $tc->{name}\n" if $tc->{name};

                for my $out ($tc->children('skipped, passed, error, failure')->each) {
                    $tc_result = 'fail' if ($out->tag =~ m/failure|error/);
                    $content .= "# " . $out->tag . ": \n\n";
                    $content .= $out->{message} . "\n" if $out->{message};
                    $content .= $out->text . "\n";
                }

                push @{$result->{details}}, {text => $text_fn, title => $tc->{name}, result => $tc_result};

                $self->_add_output(
                    {
                        file => $text_fn,
                        content => $content
                    });
                $num++;
            });

        $result->{name} = $ts_name;
        $self->_add_result(%$result);
        $i++;
    }
    $self;
}

# Schema
{
    package OpenQA::Parser::Result::XUnit;
    use Mojo::Base 'OpenQA::Parser::Result::OpenQA';
    has properties => sub { OpenQA::Parser::Results->new };

    has [qw(errors tests failures time)];
}

{
    package OpenQA::Parser::Result::XUnit::Property;
    use Mojo::Base 'OpenQA::Parser::Result';

    has [qw(name value)];
}

=head1 NAME

OpenQA::Parser::Format::XUnit - XUnit file parser

=head1 SYNOPSIS

    use OpenQA::Parser::Format::XUnit;

    my $parser = OpenQA::Parser::Format::XUnit->new()->load('file.xml');

    # Alternative interface
    use OpenQA::Parser qw(parser p);

    my $parser = p('XUnit')->include_result(1)->load('file.xml');

    my $parser = parser( XUnit => 'file.xml' );

    my $result_collection = $parser->results();
    my $test_collection   = $parser->tests();
    my $output_collection = $parser->output();

    $parser->results->remove(0);

=head1 DESCRIPTION

OpenQA::Parser::Format::XUnit is the parser for the xunit file format.
The parser is making use of the C<tests()>, C<results()> and C<output()> collections.

With the attribute C<include_result()> set to true, it will include inside the
results the respective test that generated it (inside the C<test()> attribute).
See also L<OpenQA::Parser::Result::OpenQA>.

The C<results()> is a special collection that contains L<OpenQA::Parser::Result::XUnit>
elements. OpenQA::Parser::Result::XUnit exposes the attribute C<properties()> which
is a collection of type OpenQA::Parser::Result::XUnit::Property, which represent
generic properties that each result can have in form of key/value.

    my $parser  = parser( XUnit => 'file.xml' );

    my $p_name  = $parser->results()->first->properties->first->name;
    my $p_value = $parser->results()->first->properties->first->value;

    my $all_prop_first_result = $parser->results()->first->properties;

    ...

    $all_prop_first_result->each(sub { ... });


=head1 ATTRIBUTES

OpenQA::Parser::Format::XUnit inherits all attributes from L<OpenQA::Parser::Format::JUnit>.

=head1 METHODS

OpenQA::Parser::Format::XUnit inherits all methods from L<OpenQA::Parser::Format::JUnit>, it only overrides
C<parse()> to generate a tree of results.

=cut

1;
