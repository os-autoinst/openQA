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

package OpenQA::Parser::Result;
use Mojo::Base -base;
use OpenQA::Parser::Results;
use Mojo::File 'path';
use Mojo::JSON qw(decode_json encode_json);

has details => sub { [] };
has dents => 0;
has [qw(result name test)];

sub TO_JSON {
    {
        result  => $_[0]->result(),
        dents   => $_[0]->dents(),
        details => $_[0]->details(),
        (test => $_[0]->test ? $_[0]->test->to_hash : undef) x !!($_[1])};
}

*to_hash = \&TO_JSON;

sub search_in_details {
    my ($self, $field, $re) = @_;
    my $results = OpenQA::Parser::Results->new();
    $results->add($_) for grep { $_->{$field} =~ $re } @{$self->details};
    $results;
}

sub write {
    my ($self, $dir) = @_;
    path($dir, join('.', join('-', 'result', $self->name), 'json'))->spurt(encode_json($self));
}

1;
