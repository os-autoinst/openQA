# Copyright (C) 2017-2020 SUSE LLC
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

package OpenQA::Parser::Result::Output;
use Mojo::Base 'OpenQA::Parser::Result';

# OpenQA test result class - this is how openQA internally draws the output results
# Used while parsing from format X to OpenQA test modules.
use Mojo::File 'path';

has 'file';
has 'content';

sub write {
    my ($self, $dir) = @_;
    my $content = $self->content;
    path($dir, $self->file)->spurt($content);
    return length $content;
}

1;

=encoding utf-8

=head1 NAME

OpenQA::Parser::Result::Output - OpenQA output result class

=head1 SYNOPSIS

    use OpenQA::Parser::Result::Output;

    my $output = OpenQA::Parser::Result::Output->new( file => 'awesome.txt', content => 'bar' );

    $output->write('dir');

    # Get data
    my $file_name = $output->file();
    my $content   = $output->content();

    # Set
    $output->file('awesome_2.txt');
    $output->content('');

=head1 DESCRIPTION

OpenQA::Parser::Result::Output it is representing an openQA result output (logs, texts ...).

=head1 ATTRIBUTES

OpenQA::Parser::Result::Output inherits all attributes from L<OpenQA::Parser::Result>
and implements the following new ones:

=head2 file

    use OpenQA::Parser::Result::Output;

    my $output = OpenQA::Parser::Result::Output->new( file => 'awesome.txt', content => 'bar' );

    my $file_name = $output->file();
    $output->file('awesome_2.txt');

Sets/Gets the file name.

=head2 content

    use OpenQA::Parser::Result::Output;

    my $output = OpenQA::Parser::Result::Output->new( file => 'awesome.txt', content => 'bar' );

    my $content = $output->content();
    $output->content('Awesome!');

Sets/Gets the file content.

=head1 METHODS

OpenQA::Parser::Result::Output inherits all methods from L<OpenQA::Parser::Result>
and implements the following new ones:

=head2 write()

    use OpenQA::Parser::Result::Output;

    my $output = OpenQA::Parser::Result::Output->new( file => 'awesome.txt', content => 'bar' );

    $output->write('directory/');

It will write the file content in the supplied directory.

=cut
