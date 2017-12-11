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

package OpenQA::Parser::JUnit;

use Mojo::Base 'OpenQA::Parser';
use Carp qw(croak confess);

sub parse {
    my ($self, $xml) = @_;
    confess "No XML given/loaded" unless $xml;
    $self->_dom(Mojo::DOM->new($xml));

    my $dom = $self->_dom();
    my @tests;
    for my $ts ($dom->find('testsuite')->each) {
        my $ts_category = $ts->{package};
        my $script = $ts->{script} ? $ts->{script} : undef;

        $ts_category =~ s/[^A-Za-z0-9._-]/_/g;    # the name is used as part of url so we must strip special characters
        my $ts_name = $ts_category;
        $ts_category =~ s/\..*$//;
        $ts_name =~ s/^[^.]*\.//;
        $ts_name =~ s/\./_/;
        if ($ts->{id} =~ /^[0-9]+$/) {
            # make sure that the name is unique
            # prepend numeric $ts->{id}, start counting from 1
            $ts_name = ($ts->{id} + 1) . '_' . $ts_name;
        }
        $self->_add_test(
            {
                flags    => {},
                category => $ts_category,
                name     => $ts_name,
                script   => $script,
            });

        my $ts_result = 'ok';
        $ts_result = 'fail' if $ts->{failures} || $ts->{errors};

        my $result = {
            result  => $ts_result,
            details => [],
            dents   => 0,
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
                $tc_result =~ s/^failure$/fail/;     # test failed
            }

            my $details = {result => $tc_result};

            my $text_fn = "$ts_category-$ts_name-$num.txt";
            my $content = "# $tc->{name}\n";
            for my $out ($tc->children('system-out, system-err, failure')->each) {
                $content .= "# " . $out->tag . ": \n\n";
                $content .= $out->text . "\n";
            }
            $details->{text}  = $text_fn;
            $details->{title} = $tc->{name};

            push @{$result->{details}}, $details;

            $self->_add_output(
                {
                    file    => $text_fn,
                    content => $content
                });
            $num++;
        }
        $result->{name} = $ts_name;
        $self->_add_result(%$result);
    }
    $self;
}
sub to_html { }

!!42;
