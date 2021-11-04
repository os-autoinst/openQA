# Copyright 2017-2018 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Parser::Format::JUnit;
use Mojo::Base 'OpenQA::Parser::Format::Base';

# Translates to JUnit -> openQA internal
use Carp qw(croak confess);
use OpenQA::Parser::Result::OpenQA;
use Mojo::DOM;

has include_results => 0;

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
    my ($self, $xml) = @_;
    confess "No XML given/loaded" unless $xml;
    my $dom = Mojo::DOM->new($xml);
    confess "Failed parsing XML" unless @{$dom->tree} > 2;

    my @tests;
    for my $ts ($dom->find('testsuite')->each) {
        my $ts_category = $ts->{package};
        my $script = $ts->{script} ? $ts->{script} : undef;

        $ts_category =~ s/[^A-Za-z0-9._-]/_/g;    # the name is used as part of url so we must strip special characters
        my $ts_name = $ts_category;
        $ts_category =~ s/\..*$//;
        $ts_name =~ s/^[^.]*\.//;
        $ts_name =~ s/\./_/;
        if (($ts->{id} // '') =~ /^[0-9]+$/) {
            # make sure that the name is unique
            # prepend numeric $ts->{id}, start counting from 1
            $ts_name = ($ts->{id} + 1) . '_' . $ts_name;
        }
        $self->_add_test(
            {
                flags => {},
                category => $ts_category,
                name => $ts_name,
                script => $script,
            });

        my $ts_result = 'ok';
        if ($ts->{failures} || $ts->{errors}) {
            $ts_result = 'fail';
        }
        elsif ($ts->{softfailures}) {
            $ts_result = 'softfail';
        }

        my $result = {
            result => $ts_result,
            details => [],
            dents => 0,
        };

        my $num = 1;
        for my $tc ($ts, $ts->children('testcase')->each) {

       # create extra entry for whole testsuite  if there is any system-out or system-err outside of particular testcase
            next if ($tc->tag eq 'testsuite' && $tc->children('system-out, system-err')->size == 0);

            my $tc_result = $ts_result;    # use overall testsuite result as fallback
            if (defined $tc->{status}) {
                $tc_result = $tc->{status};
                $tc_result =~ s/^success$/ok/;
                $tc_result =~ s/^skipped$/missing/;
                $tc_result =~ s/^error$/unknown/;    # error in the testsuite itself
                $tc_result =~ s/^failure$/fail/;    # test failed
                $tc_result =~ s/^softfail.*$/softfail/;    # test softfailed
            }

            if ($tc_result eq 'fail') {
                $result->{result} = 'fail';
            }
            elsif ($tc_result eq 'softfail' && $result->{result} ne 'fail') {
                $result->{result} = 'softfail';
            }

            my $details = {result => $tc_result};
            my $text_fn = "$ts_category-$ts_name-$num";
            $text_fn =~ s/[\/.]/_/g;
            $text_fn .= '.txt';
            my $content = "# $tc->{name}\n";
            for my $out ($tc->children('system-out, system-err, failure, error, skipped')->each) {
                $content .= "# " . $out->tag . ": \n\n";
                $content .= $out->text . "\n";
            }
            $details->{text} = $text_fn;
            $details->{title} = $tc->{name};

            push @{$result->{details}}, $details;

            $self->_add_output(
                {
                    file => $text_fn,
                    content => $content
                });
            $num++;
        }
        $result->{name} = $ts_name;
        $self->_add_result(%$result);
    }
    $self;
}

=encoding utf-8

=head1 NAME

OpenQA::Parser::Format::JUnit - JUnit file parser

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

This JUnit format was originally used for slenkins tests but is now used for
different purposes. If you wish to use generic JUnit format it is still
recommend to use XUnit format instead.

=head1 ATTRIBUTES

OpenQA::Parser::Format::JUnit inherits all attributes from L<OpenQA::Parser::Format::Base>.

=head1 METHODS

OpenQA::Parser::Format::JUnit inherits all methods from L<OpenQA::Parser::Format::Base>, it only overrides
C<parse()> to generate a tree of results.

=cut

1;
