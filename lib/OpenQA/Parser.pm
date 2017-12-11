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

package OpenQA::Parser;

use Mojo::Base -base;
use Carp qw(croak confess);
use Mojo::File 'path';
use Mojo::Collection;
use OpenQA::Parser::Result::Test;
use OpenQA::Parser::Result::Output;
use OpenQA::Parser::Result;
use OpenQA::Parser::Results;
has include_results => 0;

has generated_tests => sub { OpenQA::Parser::Results->new };    #testsuites
has generated_tests_results =>
  sub { OpenQA::Parser::Results->new };    #testsuites results - when include_result is set it includes also the test.
has generated_tests_output => sub { OpenQA::Parser::Results->new };    #testcase results

has [qw(_dom)];

*results = \&generated_tests_results;
*tests   = \&generated_tests;
*outputs = \&generated_tests_output;

sub load {
    my ($self, $file) = @_;
    croak "You need to specify a file" if !$file;
    my $xml = $self->_read_file($file);
    confess "Failed reading XML file $file" if !$xml;
    $self->parse($xml);
    $self;
}

sub write_output {
    my ($self, $dir) = @_;
    croak "You need to specify a directory" unless $dir;
    path($dir)->make_path unless -d $dir;
    $self->generated_tests_output->map(sub { $_->write($dir) });
    $self;
}

sub write_test_result {
    my ($self, $dir) = @_;
    croak "You need to specify a directory" unless $dir;
    path($dir)->make_path unless -d $dir;
    $self->generated_tests_results->map(sub { $_->write($dir) });
    $self;
}

sub parse          { croak 'parse() not implemented by base class' }
sub to_openqa_test { croak 'to_openqa_test() not implemented by base class' }
sub to_html        { croak 'to_html() not implemented by base class' }

sub _read_file { path($_[1])->slurp() }
sub _add_test  { shift->generated_tests->add(OpenQA::Parser::Result::Test->new(@_)) }

sub _add_single_result { shift->generated_tests_results->add(OpenQA::Parser::Result->new(@_)) }
sub _add_result {
    my $self = shift;
    my %opts = @_;
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

sub _add_output { shift->generated_tests_output->add(OpenQA::Parser::Result::Output->new(@_)) }

!!42;
