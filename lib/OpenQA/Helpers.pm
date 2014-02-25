# Copyright (C) 2014 SUSE Linux Products GmbH
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
# with this program; if not, write to the Free Software Foundation, Inc.,
# 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.

package OpenQA::Helpers;

use strict;
use warnings;
# TODO: Move all needed subs form awstandard to here.
use awstandard;
use Mojo::ByteStream;

use base 'Mojolicious::Plugin';

sub register {

    my ($self, $app) = @_;

    $app->helper(AWisodatetime2 => sub { shift; return AWisodatetime2(shift); });

    $app->helper(syntax_highlight => sub {
        my $c=shift;
        my $script=shift;
        $script=~s{^sub is_applicable}{# this function decides if the test shall run\n$&}m;
        $script=~s{^sub run}{# this part contains the steps to run this test\n$&}m;
        $script=~s{^sub checklist}{# this part contains known hash values of good or bad results\n$&}m;
        eval "require Perl::Tidy;" or return "<pre>$script</pre>";
        push(@ARGV,"-html", "-css=/dev/null");
        my @out;
        Perl::Tidy::perltidy(
            source => \$script,
            destination => \@out,
        );
        my $out=join("",@out);
        #$out=~s/.*<body>//s;
        $out=~s/.*<!-- contents of filename: perltidy -->//s;
        $out=~s{</body>.*}{}s;
        return $out;
    });

    # Breadcrumbs generation can be centralized, since it's really simple
    $app->helper(breadcrumbs => sub {
        my $c = shift;

        my $crumbs = '<div id="breadcrump" class="grid_13 alpha">';
        $crumbs .= '<a href="'.$c->url_for('/').'">';
        $crumbs .= $c->image('/images/home_grey.png', alt => "Home");
        $crumbs .= '<b>'.$c->stash('appname').'</b></a>';
        if ($c->current_route('tests')) {
            $crumbs .= ' > Test results';
        } elsif (my $test = $c->param('testid')) {
            my $testname = $c->stash('testname') || $test;
            $crumbs .= ' > '.$c->link_to('Test results' => $c->url_for('tests'));
            if ($c->current_route('test')) {
                $crumbs .= " > $testname";
            } else {
                $crumbs .= ' > '.$c->link_to($testname => $c->url_for('test'));
                my $mod = $c->param('moduleid');
                $crumbs .= " > $mod" if $mod;
            }
        } elsif ($c->current_route('build')) {
            $crumbs .= ' > '.$c->link_to('Test results' => $c->url_for('tests'));
            $crumbs .= ' > '.$c->param('buildid');
        }
        $crumbs .= '</div>';

        Mojo::ByteStream->new($crumbs);
    });

    $app->helper(current_user => sub {
        my $c = shift;
        if (my $id = $c->session->{user}) {
            my ($path, $user) = split(/\/([^\/]+)$/, $id);
            $user;
        } else {
            undef;
        }
    });

}

1;
