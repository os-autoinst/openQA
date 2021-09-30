# Copyright 2017 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Parser::Result::Test;
use Mojo::Base 'OpenQA::Parser::Result';

# OpenQA test result class - this is how test modules are represented in openQA
# Used while parsing from format X to OpenQA test modules.

has flags => sub { {} };
has [qw(category name script)];

sub to_openqa {
    my $self = shift;
    return {
        category => $self->category(),
        name => $self->name(),
        flags => $self->flags(),
        script => $self->script() // 'unk',
    };
}

# Fix JSON encoding only to those fields
sub TO_JSON {
    my $self = shift;
    return {
        category => $self->category(),
        name => $self->name(),
        flags => $self->flags(),
        script => $self->script() // 'unk',
    };
}

1;

=encoding utf-8

=head1 NAME

OpenQA::Parser::Result::Test - OpenQA Test information result class

=head1 SYNOPSIS

    use OpenQA::Parser::Result::Test;

    my $test = OpenQA::Parser::Result::Test->new( flags    => { ... },
                                                  category => 'some',
                                                  name     => 'wonderful_test',
                                                  script   => '/path/to/script' );

    my %flags    = %{ $test->flags() };
    my $category = $test->category();
    my $name     = $test->name();
    my $script   = $test->script();

    $test->flags({ ... });
    $test->category('foo');
    $test->name('awesome_test');
    $test->script('/path/to/another/script');

=head1 DESCRIPTION

OpenQA::Parser::Result::Test it is representing an openQA test information.
Elements of the parser tree that wish to map it's data with openQA needs to inherit this class.

=head1 ATTRIBUTES

OpenQA::Parser::Result::Test inherits all attributes from L<OpenQA::Parser::Result>
and implements the following new ones: C<flags()>, C<category()>, C<name()> and C<script()>.
Respectively mapping the openQA test information fields.

=head1 METHODS

OpenQA::Parser::Result::Test inherits all methods from L<OpenQA::Parser::Result>
and implements the following new ones:

=head2 to_openqa()

    use OpenQA::Parser::Result::Test;

    my $test = OpenQA::Parser::Result::Test->new( flags    => { ... },
                                                  category => 'some',
                                                  name     => 'wonderful_test',
                                                  script   => '/path/to/script' );

    my $info = $test->to_openqa;
    # $info is { flags => { ... }, category => 'some', name => 'wonderful_test', script   => '/path/to/script' }

It will return a hashref which contains as elements the only one strictly required by openQA
to parse the test.

=cut
