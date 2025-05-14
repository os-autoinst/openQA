# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Parser::Format::KTAP;
use Mojo::Base 'OpenQA::Parser::Format::Base', -signatures;

# Translates KTAP kernel selftests format -> OpenQA internal representation
use Carp qw(croak confess);
use OpenQA::Parser::Result::OpenQA;
use TAP::Parser;

has [qw(test)];

sub _testgroup_init ($self, $line, $test_ref, $steps_ref, $m_ref) {
    if ($$steps_ref && $self->test) {
        $$steps_ref->{name} = $self->test->{name};
        $$steps_ref->{test} = $self->test;
        $self->generated_tests_results->add(OpenQA::Parser::Result::OpenQA->new($$steps_ref));
    }
    my ($group_name) = $line =~ /^#\s*selftests:\s+(.*)/;
    my $sanitized_group_name = "selftests: $group_name";
    $sanitized_group_name =~ s/[\/.]/_/g;
    $$test_ref = {
        flags => {},
        category => 'KTAP',
        name => $sanitized_group_name,
    };
    $self->test(OpenQA::Parser::Result->new($$test_ref));
    $self->_add_test($self->test);
    $$steps_ref = OpenQA::Parser::Result->new(
        {
            details => [],
            dents => 0,
            result => 'passed'
        });

    $$m_ref = 0;
}

sub _parse_subtest ($self, $result, $test_ref, $steps_ref, $m_ref) {
    return unless $$steps_ref && $self->test;
    my $line = $result->as_string;
    return unless $line =~ /^#\s*(ok|not ok)\s+\d+\s+(.+)/;
    my ($status, $subtest_name) = ($1, $2);
    my $filename = "KTAP-@{[$$test_ref->{name}]}-$$m_ref.txt";
    push @{$$steps_ref->{details}},
      {
        text => $filename,
        title => $subtest_name,
        result => $status eq 'ok' ? 'ok' : 'fail',
      };
    $$steps_ref->{result} = 'fail' if $status ne 'ok';
    $self->_add_output({file => $filename, content => $line});
    $$m_ref++;
}

sub _testgroup_finalize ($self, $steps_ref, $result) {
    return unless $$steps_ref && $self->test;

    my $line = $result ? $result->as_string : '';
    my $group_failed = 0;    # it is possible the subtests do not report 'not ok' but only the group
    if ($line =~ /^not ok\b/i) {
        $$steps_ref->{result} = 'fail';
        $group_failed = 1;
    }
    elsif ($line =~ /#\s*SKIP\b/i) {
        $$steps_ref->{result} = 'skip';
    }
    $$steps_ref->{name} = $self->test->{name};
    $$steps_ref->{test} = $self->test;
    $self->generated_tests_results->add(OpenQA::Parser::Result::OpenQA->new($$steps_ref));
    $self->test(undef);    # clear the group
    $$steps_ref = undef;    # clear the subtests
}

sub parse ($self, $KTAP) {
    my $parser = TAP::Parser->new({tap => $KTAP});
    confess 'Failed ' . $parser->parse_errors if $parser->parse_errors;
    my ($test, $steps, $m) = ({}, undef, 0);

    while (my $result = $parser->next) {
        next if $result->type eq 'version' || $result->type eq 'plan';
        if ($result->type eq 'comment' && $result->as_string =~ /^#\s*selftests:\s+(.*)/) {
            $self->_testgroup_init($result->as_string, \$test, \$steps, \$m);
            next;
        }
        if ($result->type eq 'comment' && $result->as_string =~ /^#\s*(ok|not ok)\s+\d+\s+(.+)/) {
            $self->_parse_subtest($result, \$test, \$steps, \$m);
            next;
        }
        if ($result->type eq 'test' && $result->description =~ /^selftests: /) {
            $self->_testgroup_finalize(\$steps, $result);
            next;
        }
    }

    if ($steps && $self->test) {
        $steps->{name} = $self->test->{name};
        $steps->{test} = $self->test;
        $self->generated_tests_results->add(OpenQA::Parser::Result::OpenQA->new($steps));
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
The parser is making use of the C<tests()>, C<results()> and C<output()> collections.

This parser extracts:
- Test groups (`selftests: ...`)
- Subtest results (`# ok ...`, `# not ok ...`)
- Final group summary lines (`ok N selftests: ...`)

It populates internal result structures that can later be queried using standard OpenQA::Parser accessors.

=head1 ATTRIBUTES

Inherits from L<OpenQA::Parser::Format::Base>. Additional attributes include:

=head2 test

An instance of L<OpenQA::Parser::Result> representing the current test group being parsed.

=head2 steps

A temporary result object accumulating the individual subtest results for the current test group.

=head1 METHODS

=head2 _testgroup_init($line, $test_ref, $steps_ref, $m_ref)

Initializes a new test group when a C<# selftests: groupname> comment is encountered.

=head2 _parse_subtest($result, $test_ref, $steps_ref, $m_ref)

Parses a subtest line of the form C<# ok 1 testname> and appends the result to the current steps.

=head2 _testgroup_finalize($steps_ref)

Finalizes the current test group and stores the accumulated results.

=cut

1;
