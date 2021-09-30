# Copyright 2018 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Parser::Format::IPA;
use Mojo::Base 'OpenQA::Parser::Format::Base';

# Translates to JSON IPA format -> OpenQA internal representation
# The parser results will be a collection of OpenQA::Parser::Result::IPA::Test
use Carp qw(croak confess);
use Mojo::JSON;
use OpenQA::Parser::Result::Test;

sub _add_single_result { shift->results->add(OpenQA::Parser::Result::OpenQA->new(@_)) }

# Parser
sub parse {
    my ($self, $json) = @_;
    confess "No JSON given/loaded" unless $json;
    my $decoded_json = Mojo::JSON::from_json($json);
    my %unique_names;

    # may be optional since format result_array:v2
    $self->generated_tests_extra->add(OpenQA::Parser::Result::IPA::Info->new($decoded_json->{info}))
      if $decoded_json->{info};

    foreach my $res (@{$decoded_json->{tests}}) {
        my $result = {};
        my $t_name = $res->{nodeid} // $res->{name};
        die 'IPA result misses test name / node ID' unless $t_name;

        if ($t_name =~ /^(?<path>[\w\/]+\/)?(?<file>\w+)\.py::(?<method>\w+)\[\w+:\/\/(\d+\.){3}\d+(-(?<param>.+))?\]$/)
        {
            $t_name = '';
            $t_name .= $+{path} if ($+{path});
            $t_name .= $+{file};
            $t_name .= '_' . $+{method} if ($+{file} ne $+{method});
            if ($+{param}) {
                my $param = $+{param};
                $param =~ s/\.service$//;
                $t_name .= '_' . $param;
            }
        }

        # If a test was triggered twice, we need to unique the name
        if (exists($unique_names{$t_name})) {
            $t_name .= sprintf('_%02d', ++$unique_names{$t_name});
        }
        else {
            $unique_names{$t_name} = 0;
        }

        # replace everything which confuses the web api routes
        $t_name =~ s/[:\/\[\]\.]/_/g;

        $result->{result} = 'fail';
        $result->{result} = 'ok' if $res->{outcome} =~ /passed/i;
        $result->{result} = 'skip' if $res->{outcome} =~ /skipped/i;

        $result->{name} = $t_name;

        my $details = {result => $result->{result}};
        my $text_fn = "IPA-$t_name.txt";
        my $content = join("\n", $t_name, $result->{result});

        $details->{text} = $text_fn;
        $details->{title} = $t_name;

        push @{$result->{details}}, $details;

        $self->_add_output(
            {
                file => $text_fn,
                content => $content
            });

        my $t = OpenQA::Parser::Result::Test->new(
            flags => {},
            category => 'IPA',
            name => $t_name,
            script => undef,
            result => $result->{result});
        $self->tests->add($t);
        $result->{test} = $t if $self->include_results();
        $self->_add_single_result($result);
    }

    $self;
}

{
    package OpenQA::Parser::Result::IPA::Info;
    use Mojo::Base 'OpenQA::Parser::Result';

    has [qw(distro platform image instance region results_file log_file timestamp)];
}

=head1 NAME

OpenQA::Parser::Format::IPA - IPA file parser

=head1 SYNOPSIS

    use OpenQA::Parser::Format::IPA;

    my $parser = OpenQA::Parser::Format::IPA->new()->load('file.json');

    # Alternative interface
    use OpenQA::Parser qw(parser p);

    my $parser = p('IPA')->include_result(1)->load('file.json');

    my $parser = parser( IPA => 'file.json' );

    my $result_collection = $parser->results();
    my $test_collection   = $parser->tests();
    my $extra_collection  = $parser->extra();

    my $info = $parser->extra()->first;  # Get system information

    my $arrayref = $extra_collection->to_array;

    $parser->results->remove(0);

    my $passed_results = $parser->results->search( result => qr/ok/ );
    my $size = $passed_results->size;

=head1 DESCRIPTION

OpenQA::Parser::Format::IPA is the parser for the ipa file format.
The parser is making use of the C<tests()>, C<results()>, C<output()> and C<extra()> collections.

With the attribute C<include_result()> set to true, it will include inside the
results the respective test that generated it (inside the C<test()> attribute).
See also L<OpenQA::Parser::Result::OpenQA>.

The C<extra()> collection can include the environment of the tests shared among the results.
After the parsing, depending on the processed file, it should contain one element,
which is the environment.

    my $parser = parser( IPA => 'file.json' );

    my $environment = $parser->extra()->first;

Results objects are of specific type, as they are including additional attributes that are
supported only by the format (thus not by openQA).

=head1 ATTRIBUTES

OpenQA::Parser::Format::IPA inherits all attributes from L<OpenQA::Parser::Format::Base>.

=head1 METHODS

OpenQA::Parser::Format::IPA inherits all methods from L<OpenQA::Parser::Format::Base>, it only overrides
C<parse()> to generate a tree of results.

=cut

1;
