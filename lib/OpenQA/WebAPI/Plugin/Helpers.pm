# Copyright (C) 2015 SUSE Linux GmbH
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

package OpenQA::WebAPI::Plugin::Helpers;

use strict;
use warnings;
use Mojo::ByteStream;
use OpenQA::Utils qw(bugurl);
use db_helpers;

use base 'Mojolicious::Plugin';

sub register {

    my ($self, $app) = @_;

    $app->helper(
        format_time => sub {
            my ($c, $timedate, $format) = @_;
            return unless $timedate;
            $format ||= "%Y-%m-%d %H:%M:%S %z";
            return $timedate->strftime($format);
        });

    $app->helper(
        format_time_duration => sub {
            my ($c, $timedate) = @_;
            return unless $timedate;
            if ($timedate->hours() > 0) {
                sprintf("%02d:%02d hours", $timedate->hours(), $timedate->minutes());
            }
            else {
                sprintf("%02d:%02d minutes", $timedate->minutes(), $timedate->seconds());
            }
        });

    $app->helper(
        bugurl_for => sub {
            my ($c, $text) = @_;
            if ($text =~ /(.*)#(.*)/) {
                return bugurl($1) . $2;
            }
            return;
        });

    $app->helper(
        bugicon_for => sub {
            my ($c, $text) = @_;
            return ($text =~ /poo#/) ? 'label_bug fa fa-bolt' : 'label_bug fa fa-bug';
        });

    # Breadcrumbs generation can be centralized, since it's really simple
    $app->helper(
        breadcrumbs => sub {
            my $c = shift;

            my $crumbs = '<div id="breadcrump" class="breadcrumb grid_10 alpha">';
            $crumbs .= '<a href="' . $c->url_for('/') . '">';
            $crumbs .= $c->image('/images/home_grey.png', alt => "Home");
            $crumbs .= '<b>' . $c->stash('appname') . '</b></a>';

            my $test = $c->param('testid');

            if ($test || $c->current_route =~ /^tests/) {
                $crumbs .= ' > ' . $c->link_to('Test results' => $c->url_for('tests'));
            }
            elsif ($c->current_route =~ /^admin/) {
                $crumbs .= ' > ' . $c->link_to(Admin => $c->url_for('admin'));
                $crumbs .= ' > ' . $c->stash('title');
            }

            if ($test) {
                my $distri  = $c->stash('distri');
                my $build   = $c->stash('build');
                my $version = $c->stash('version');

                my $query = {build => $build, distri => $distri, version => $version};
                my $job = $c->stash('job');
                if ($job->group_id) {
                    $query->{groupid} = $job->group_id;
                    $crumbs .= ' > ' . $c->link_to("Build$build\@" . $job->group->name => $c->url_for('tests_overview')->query(%$query));
                }
                else {
                    $crumbs .= ' > ' . $c->link_to("Build$build\@$distri $version" => $c->url_for('tests_overview')->query(%$query));
                }
                if ($c->current_route('test')) {
                    $crumbs .= " > Test $test";
                }
                else {
                    $crumbs .= ' > ' . $c->link_to("Test $test" => $c->url_for('test'));
                    my $mod = $c->param('moduleid');
                    $crumbs .= " > $mod" if $mod;
                }
            }
            elsif ($c->current_route('tests_overview')) {
                $crumbs .= ' > Build overview';
            }

            $crumbs .= '</div>';

            Mojo::ByteStream->new($crumbs);
        });

    $app->helper(
        db => sub {
            my $c = shift;
            $c->app->schema;
        });

    $app->helper(
        current_user => sub {
            my $c = shift;

            # If the value is not in the stash
            if (!(defined($c->stash('current_user')) && ($c->stash('current_user')->{no_user} || defined($c->stash('current_user')->{user})))) {

                my $user = undef;
                if (my $id = $c->session->{user}) {
                    $user = $c->db->resultset("Users")->find({username => $id});
                }
                if ($user) {
                    $c->stash(current_user => {user => $user});
                }
                else {
                    $c->stash(current_user => {no_user => 1});
                }
            }
            my $is_user_def = defined($c->stash('current_user'))
              && defined($c->stash('current_user')->{user});

            return $is_user_def ? $c->stash('current_user')->{user} : undef;
        });

    $app->helper(
        is_operator => sub {
            my $c = shift;
            my $user = shift || $c->current_user;

            return ($user && $user->is_operator);
        });

    $app->helper(
        is_admin => sub {
            my $c = shift;
            my $user = shift || $c->current_user;

            return ($user && $user->is_admin);
        });

    $app->helper(
        # CSS class for a job or module based on its result
        css_for => sub {
            my ($c, $hash) = @_;
            return unless $hash;
            my $res = $hash->{result};

            if ($res eq 'na' || $res eq 'incomplete') {
                return '';
            }
            elsif ($res =~ /^fail/) {
                return 'resultfail';
            }
            elsif ($res eq 'passed') {
                return $hash->{soft_failure} ? 'resultsoftfailed' : 'resultok';
            }
            else {
                return 'resultunknown';
            }
        });
    $app->helper(
        format_result => sub {
            my ($c, $module) = @_;
            return unless $module;
            my $res = $module->{result};

            if ($res eq 'na') {
                return 'n/a';
            }
            elsif ($res eq 'unk') {
                return 'unknown';
            }
            elsif ($res eq 'passed' && $module->{soft_failure}) {
                return 'soft failed';
            }
            else {
                return $res;
            }
        });

    $app->helper(
        # Just like 'include', but includes the template with the given
        # name from the correct directory for the 'branding' config setting
        # falls back to 'plain' if brand doesn't include the template, so
        # allowing partial brands
        include_branding => sub {
            my ($c, $name) = @_;
            my $path = "branding/" . $c->app->config->{global}->{branding} . "/$name";
            my $ret  = $c->render_to_string($path);
            if (defined($ret)) {
                return $ret;
            }
            else {
                $path = "branding/plain/$name";
                return $c->render_to_string($path);
            }
        });

    $app->helper(step_thumbnail => \&_step_thumbnail);

    $app->helper(
        # emit_event helper, adds user, connection to events
        emit_event => sub {
            my ($self, $event, $data) = @_;
            die 'Missing event name' unless $event;
            return Mojo::IOLoop->singleton->emit($event, [$self->current_user->id, $self->tx->connection, $event, $data]);
        });

    $app->helper(
        trim_text => sub {
            my ($c, $text, $length) = @_;
            $length //= 10;
            return $text if (length($text) < $length);

            return $c->tag('span', title => $text, sub { substr($text, 0, $length - 4) . " ..." });
        });
}

sub _step_thumbnail {
    my ($c, $screenshot, $ref_width, $testid, $module, $step_num) = @_;

    my $ref_height = int($ref_width / 4 * 3);

    my $imgurl;
    if ($screenshot->{md5_dirname}) {
        $imgurl = $c->url_for(
            'thumb_image',
            md5_dirname  => $screenshot->{md5_dirname},
            md5_basename => $screenshot->{md5_basename});
    }
    else {
        $imgurl = $c->url_for('test_thumbnail', testid => $testid, filename => $screenshot->{screenshot});
    }
    my $result = lc $screenshot->{result};
    $result = 'softfail' if grep { $_ eq 'workaround' } (@{$screenshot->{properties} || []});
    my $content = $c->image(
        $imgurl => width => $ref_width,
        height  => $ref_height,
        alt     => $screenshot->{name},
        class   => "resborder resborder_$result"
    );
    return $content;
}

1;
# vim: set sw=4 et:
