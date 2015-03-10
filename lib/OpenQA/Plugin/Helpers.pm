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

package OpenQA::Plugin::Helpers;

use strict;
use warnings;
use Mojo::ByteStream;
use db_helpers;

use base 'Mojolicious::Plugin';

sub register {

    my ($self, $app) = @_;

    $app->helper(
        format_time => sub {
            my $c = shift;
            my $timedate = shift || return undef;
            my $format = shift || "%Y-%m-%d %H:%M:%S";
            return $timedate->strftime($format);
        }
    );

    $app->helper(
        format_time_duration => sub {
            my $c = shift;
            my $timedate = shift || return undef;
            return sprintf("%02d:%02d:%02d", $timedate->hours(), $timedate->minutes(), $timedate->seconds());
        }
    );

    # Breadcrumbs generation can be centralized, since it's really simple
    $app->helper(
        breadcrumbs => sub {
            my $c = shift;

            my $crumbs = '<div id="breadcrump" class="grid_10 alpha">';
            $crumbs .= '<a href="'.$c->url_for('/').'">';
            $crumbs .= $c->image('/images/home_grey.png', alt => "Home");
            $crumbs .= '<b>'.$c->stash('appname').'</b></a>';

            my $test = $c->param('testid');

            if ($test || $c->current_route =~ /^tests/) {
                $crumbs .= ' > '.$c->link_to('Test results' => $c->url_for('tests'));
            }
            elsif ($c->current_route =~ /^admin/) {
                $crumbs .= ' > '.$c->link_to('Admin' => $c->url_for('admin'));
                $crumbs .= ' > '.$c->stash('title');
            }

            if ($test) {
                my $testname = $c->stash('testname') || $test;
                if ($c->current_route('test')) {
                    $crumbs .= " > $testname";
                }
                else {
                    $crumbs .= ' > '.$c->link_to($testname => $c->url_for('test'));
                    my $mod = $c->param('moduleid');
                    $crumbs .= " > $mod" if $mod;
                }
            }
            elsif ($c->current_route('tests_overview')) {
                $crumbs .= ' > Build overview';
            }

            $crumbs .= '</div>';

            Mojo::ByteStream->new($crumbs);
        }
    );

    $app->helper(
        db => sub {
            my $c = shift;
            $c->app->schema;
        }
    );

    $app->helper(
        current_user => sub {
            my $c = shift;

            # If the value is not in the stash
            if ( !(defined($c->stash('current_user')) &&($c->stash('current_user')->{no_user} || defined($c->stash('current_user')->{user})))) {

                my $user = undef;
                if (my $id = $c->session->{user}) {
                    $user = $c->db->resultset("Users")->find({username => $id});
                }
                if ($user) {
                    $c->stash('current_user' => { user => $user });
                }
                else {
                    $c->stash('current_user' => { no_user => 1 });
                }
            }
            my $is_user_def = defined($c->stash('current_user'))
              && defined($c->stash('current_user')->{user});

            return $is_user_def ? $c->stash('current_user')->{user} : undef;
        }
    );

    $app->helper(
        rndstr => sub {
            my $c = shift;
            db_helpers::rndstr(@_);
        }
    );

    $app->helper(
        is_operator => sub {
            my $c = shift;
            my $user = shift || $c->current_user;

            return ($user && $user->is_operator);
        }
    );

    $app->helper(
        is_admin => sub {
            my $c = shift;
            my $user = shift || $c->current_user;

            return ($user && $user->is_admin);
        }
    );

    $app->helper(
        # CSS class for a job or module based on its result
        css_for => sub {
            my ($c, $hash) = @_;
            return undef unless $hash;
            my $res = $hash->{result};

            if ($res eq 'na' || $res eq 'incomplete') {
                return '';
            }
            elsif ($res =~ /^fail/) {
                return 'resultfail';
            }
            elsif ($res eq 'passed') {
                return 'resultok';
            }
            elsif ($res eq 'ok') {
                return $hash->{soft_failure} ? 'resultwarning' : 'resultok';
            }
            else {
                return 'resultunknown';
            }
        }
    );
    $app->helper(
        format_result => sub {
            my ($c, $module) = @_;
            return undef unless $module;
            my $res = $module->{'result'};

            if ($res eq 'na') {
                return 'n/a';
            }
            elsif ($res eq 'unk') {
                return 'unknown';
            }
            else {
                return $res;
            }
        }
    );

}

1;
# vim: set sw=4 et:
