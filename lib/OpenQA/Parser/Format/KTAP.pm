# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Parser::Format::KTAP;
use Mojo::Base 'OpenQA::Parser::Format::Base', -signatures;

# Translates KTAP kernel selftests format -> OpenQA internal representation
use Carp qw(confess);
use OpenQA::Parser::Result::OpenQA;
use TAP::Parser;

has [qw(test)];
has state => sub { return {steps => undef, m => 0} };

sub _testgroup_init ($self, $line) {
    # flush previous group if required
    if ($self->state->{steps} && $self->test) {
        my $steps = $self->state->{steps};
        $steps->{name} = $self->test->{name};
        $steps->{test} = $self->test;
        $self->generated_tests_results->add(OpenQA::Parser::Result::OpenQA->new($steps));
    }

    my ($group_name) = $line =~ /^#\s*selftests:\s+(.*)/;
    my $sanitized_group_name = "selftests: $group_name";
    $sanitized_group_name =~ s/[\/.]/_/g;
    $sanitized_group_name =~ s/\s//g;

    my $group = {
        flags => {},
        category => 'KTAP',
        name => $sanitized_group_name,
    };

    $self->test(OpenQA::Parser::Result->new($group));
    $self->_add_test($self->test);

    $self->state->{steps} = OpenQA::Parser::Result->new(
        {
            details => [],
            unparsed_lines => [],
            parsed_lines_count => 0,
            result => 'passed',
        });
    $self->state->{m} = 0;
}

sub _parse_subtest ($self, $result) {
    my $steps = $self->state->{steps} or return;
    $self->test or return;

    my $line = $result->as_string;
    unless ($line =~ /^#\s*(?<status>ok|not ok)\s+(?<index>\d+)\s+(?<name>[^#]*)/) {
        push @{$steps->{unparsed_lines}}, $line;
        return;
    }
    $steps->{parsed_lines_count}++;
    return if $line =~ /#\s*SKIP\b/i;
    my ($status, $index, $subtest_name) = @+{qw(status index name)};

    my $has_todo = $line =~ /#\s*TODO\b/i;
    my $m = $self->state->{m};
    my $filename = "KTAP-@{[$self->test->{name}]}-$m.txt";
    my $subtest_result = $has_todo ? 'softfail' : ($status eq 'ok' ? 'ok' : 'fail');

    push @{$steps->{details}},
      {
        text => $filename,
        title => $subtest_name || $index,
        result => $subtest_result,
      };

    if (!$has_todo && $status ne 'ok') {
        $steps->{result} = 'fail';
    }
    elsif ($has_todo && $steps->{result} ne 'fail') {
        $steps->{result} = 'softfail';
    }

    $self->_add_output({file => $filename, content => $line});
    $self->state->{m} = $m + 1;
}

sub _testgroup_finalize ($self, $result) {
    my $steps = $self->state->{steps} or return;
    $self->test or return;

    my $line = $result ? $result->as_string : '';
    if ($line =~ /^not ok\b/i) {
        $steps->{result} = 'fail';
    }
    elsif ($line =~ /#\s*TODO\b/i) {
        $steps->{result} = 'softfail' if $steps->{result} ne 'fail';
    }
    elsif ($line =~ /#\s*SKIP\b/i) {
        $steps->{result} = 'skip';
    }

    $steps->{name} = $self->test->{name};
    $steps->{test} = $self->test;

    # If there are no parsed lines, default to simply show the whole log.
    # This is better than not showing anything, impeding the user to see
    # the buttons of adding product or test bugs and requiring them to
    # search and open individual log assets.
    if (!$steps->{parsed_lines_count}) {
        my $filename = "KTAP-@{[$steps->{name}]}.txt";
        push @{$steps->{details}},
          {
            text => $filename,
            title => $steps->{name},
            result => 'ok',
          };
        $self->_add_output({file => $filename, content => join("\n", @{$steps->{unparsed_lines}})});
    }

    $self->generated_tests_results->add(OpenQA::Parser::Result::OpenQA->new($steps));

    $self->test(undef);
    $self->state->{steps} = undef;
    $self->state->{m} = 0;
}

sub parse ($self, $KTAP) {
    my $parser = TAP::Parser->new({tap => $KTAP});
    confess 'Failed to parse KTAP: ' . $parser->parse_errors if $parser->parse_errors;

    while (my $result = $parser->next) {
        next if $result->type eq 'version' || $result->type eq 'plan';

        if ($result->type eq 'comment') {
            if ($result->as_string =~ /^#\s*selftests:\s+/) {
                $self->_testgroup_init($result->as_string);
                next;
            }
            $self->_parse_subtest($result);
            next;
        }
        if ($result->type eq 'test' && $result->description =~ /^selftests: /) {
            $self->_testgroup_finalize($result);
            next;
        }
    }

    if (my $steps = $self->state->{steps} and $self->test) {
        $steps->{name} = $self->test->{name};
        $steps->{test} = $self->test;
        $self->generated_tests_results->add(OpenQA::Parser::Result::OpenQA->new($steps));
        $self->test(undef);
        $self->state->{steps} = undef;
        $self->state->{m} = 0;
    }
}

=head1 NAME

OpenQA::Parser::Format::KTAP - KTAP file parser

=head1 SYNOPSIS

    use OpenQA::Parser::Format::KTAP;

    my $parser = OpenQA::Parser::Format::KTAP->new()->load('test.tap');

    # Alternative interface
    use OpenQA::Parser qw(parser p);

    my $parser = p(KTAP => 'test.tap');

    my $result_collection = $parser->results();
    my $test_collection   = $parser->tests();
    my $output_collection = $parser->output();

    my $arrayref = $result_collection->to_array;

    $parser->results->remove(0);

    my $passed_results = $parser->results->search( result => qr/ok/ );
    my $size = $passed_results->size;

=head1 DESCRIPTION

B<OpenQA::Parser::Format::KTAP> parses Linux kernel selftests written in KTAP (Kernel Test Anything Protocol),
which extends TAP with structured subtests and test groups.
The parser uses the C<tests()>, C<results()> and C<output()> collections.

This parser extracts:
- Test groups (C<selftests: ...>)
- Subtest results (C<# ok ...>, C<# not ok ...>) - C<# TODO> lines are treated as C<softfail>
- Final group summary lines (C<ok N selftests: ...>, C<not ok N selftests: ...>, optional C<# SKIP> / C<# TODO> directives)

It populates internal result structures that can later be queried using standard OpenQA::Parser accessors.

=head1 ATTRIBUTES

Inherits from L<OpenQA::Parser::Format::Base>. Additional attributes include:

=head2 test

An instance of L<OpenQA::Parser::Result> representing the current test group being parsed.

=head2 state

A hashref used to accumulate transient parse state for the current test group:
`steps` (L<OpenQA::Parser::Result>) and `m` (subtest index).

=head1 METHODS

=head2 _testgroup_init($line)

Initializes a new test group when a C<# selftests: groupname> comment is encountered.

=head2 _parse_subtest($result)

Parses a subtest line of the form C<# ok 1 testname> and appends the result to the current steps.

=head2 _testgroup_finalize($result)

Finalizes the current test group and stores the accumulated results.

=head2 parse($KTAP)

Main entry point. Parses KTAP-formatted text and populates the parser's result, test, and output collections.

=cut

1;
