# Copyright (C) 2015-2016 SUSE LLC
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
use OpenQA::Utils qw(bugurl render_escaped_refs href_to_bugref);
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
            my ($c, $bugref) = @_;
            return bugurl($bugref);
        });

    $app->helper(
        bugicon_for => sub {
            my ($c, $text, $bug) = @_;
            my $css_class = ($text =~ /(poo|gh)#/) ? 'label_bug fa fa-bolt' : 'label_bug fa fa-bug';
            if ($bug && !$bug->open) {
                $css_class .= " bug_closed";
            }
            return $css_class;
        });

    $app->helper(bug_report_actions => sub { shift->include_branding('external_reporting') });

    $app->helper(
        stepaction_for => sub {
            my ($c, $title, $url, $icon, $class) = @_;
            $class //= '';
            my $icons = $c->t(i => (class => "step_action fa $icon fa-lg fa-stack-1x"))
              . $c->t(i => (class => 'new fa fa-plus fa-stack-1x'));
            my $content = $c->t(span => (class => 'fa-stack') => sub { $icons });
            return $c->link_to($url => (title => $title, class => $class) => sub { $content });
        });

    $app->helper(
        stepvideolink_for => sub {
            my ($c, $testid, $frametime) = @_;
            my $url = $c->url_for('test_file', testid => $testid, filename => 'video.ogv');
            $url .= sprintf("#t=%s,%s", ${$frametime}[0], ${$frametime}[1]);
            my $icon = $c->t(i => (class => "step_action far fa-video-file fa-lg"));
            my $class = "step_action far fa-file-video fa-lg";
            return $c->link_to($url => (title => "Jump to video", class => $class) => sub { "" });
        });

    $app->helper(
        rendered_refs_no_shortening => sub {
            my ($c, $text) = @_;
            return render_escaped_refs($text);
        });

    $app->helper(
        rendered_refs => sub {
            my ($c, $text) = @_;
            return href_to_bugref(render_escaped_refs($text));
        });

    $app->helper(
        current_job_group => sub {
            my ($c) = @_;

            if ($c->param('testid') || $c->stash('testid')) {
                my $crumbs;
                my $distri  = $c->stash('distri');
                my $build   = $c->stash('build');
                my $version = $c->stash('version');

                my $query = {build => $build, distri => $distri, version => $version};
                my $job = $c->stash('job');

                my $overview_text;
                if ($job->group_id) {
                    $query->{groupid} = $job->group_id;
                    $crumbs .= "\n<li id='current-group-overview'>";
                    $crumbs .= $c->link_to(
                        ($job->group->name . ' (current)') => $c->url_for('group_overview', groupid => $job->group_id));
                    $crumbs .= "</li>";
                    $overview_text = "Build " . $job->BUILD;
                }
                else {
                    $overview_text = "Build $build\@$distri $version";
                }
                my $overview_url = $c->url_for('tests_overview')->query(%$query);

                $crumbs .= "\n<li id='current-build-overview'>";
                $crumbs .= $c->link_to(
                    $overview_url => sub { '<i class="glyphicon glyphicon-arrow-right"></i> ' . $overview_text });
                $crumbs .= "</li>";
                $crumbs .= "\n<li role='separator' class='divider'></li>\n";
                return Mojo::ByteStream->new($crumbs);
            }
            return;
        });

    $app->helper(db => sub { shift->app->schema });

    $app->helper(
        current_user => sub {
            my $c = shift;

            # If the value is not in the stash
            my $current_user = $c->stash('current_user');
            unless ($current_user && ($current_user->{no_user} || defined $current_user->{user})) {
                my $id = $c->session->{user};
                my $user = $id ? $c->db->resultset("Users")->find({username => $id}) : undef;
                $c->stash(current_user => $current_user = $user ? {user => $user} : {no_user => 1});
            }

            return $current_user && defined $current_user->{user} ? $current_user->{user} : undef;
        });

    $app->helper(current_job => sub { shift->stash('job') });

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
                return 'resultfailed';
            }
            elsif ($res eq 'softfailed') {
                return 'resultsoftfailed';
            }
            elsif ($res eq 'passed') {
                return 'resultok';
            }
            elsif ($res eq 'running') {
                return 'resultrunning';
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
            elsif ($res eq 'softfailed') {
                return 'soft-failed';
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
        icon_url => sub {
            my ($c, $icon) = @_;
            my $json = $c->app->asset->processed($icon)->[0]->TO_JSON;
            return $c->url_for(assetpack => $json);
        });

    $app->helper(
        limit_previous_link => sub {
            my ($c, $scenario_hash, $current_limit, $limit) = @_;
            if ($current_limit eq $limit) {
                return "<b>$limit</b>";
            }
            else {
                $scenario_hash->{limit_previous} = $limit;
                return '<a href="' . $c->url_with->query(%$scenario_hash) . '#previous">' . $limit . '</a>';
            }
        });

    $app->helper(
        # generate popover help button with title, content and optional details_url
        # Examples:
        #   help_popover 'Help for me' => 'This is me'
        #   help_popover 'Help for button' => 'Do not press this button!', 'http://nuke.me' => 'Nuke'
        help_popover => sub {
            my ($c, $title, $content, $details_url, $details_text, $placement) = @_;
            my $class = 'help_popover fa fa-question-circle';
            if ($details_url) {
                $content
                  .= '<p>See '
                  . $c->link_to($details_text ? $details_text : here => $details_url, target => 'blank')
                  . ' for details</p>';
            }
            my $data = {toggle => 'popover', trigger => 'focus', title => $title, content => $content};
            $data->{placement} = $placement if $placement;
            return $c->t(a => (tabindex => 0, class => $class, role => 'button', (data => $data)));
        });

    $app->helper(
        # emit_event helper, adds user, connection to events
        emit_event => sub {
            my ($self, $event, $data) = @_;
            die 'Missing event name' unless $event;
            my $user = $self->current_user ? $self->current_user->id : undef;
            return Mojo::IOLoop->singleton->emit($event, [$user, $self->tx->connection, $event, $data]);
        });

    $app->helper(
        text_with_title => sub {
            my ($c, $text) = @_;
            return $c->tag('span', title => $text, $text);
        });

    $app->helper(
        build_progress_bar_section => sub {
            my ($c, $key, $res, $max, $class) = @_;

            $class //= '';
            if ($res) {
                return $c->tag(
                    'div',
                    class => 'progress-bar progress-bar-' . $key . ' ' . $class,
                    style => 'width: ' . ($res * 100 / $max) . '%;',
                    sub {
                        $res . ' ' . $key;
                    });
            }
            return '';
        });

    $app->helper(
        build_progress_bar_title => sub {
            my ($c, $res) = @_;
            my @keys = qw(passed unfinished softfailed failed skipped total);
            return join("\n", map("$_: $res->{$_}", grep($res->{$_}, @keys)));
        });

    $app->helper(
        group_link_menu_entry => sub {
            my ($c, $group) = @_;
            return $c->tag('li', $c->link_to($group->name => $c->url_for('group_overview', groupid => $group->id)));
        });

    $app->helper(
        comment_icon => sub {
            my ($c, $jobid, $comment_count) = @_;
            return '' unless $comment_count;

            return $c->link_to(
                $c->url_for('test', testid => $jobid) . '#' . comments => sub {
                    $c->tag(
                        'i',
                        class => 'test-label label_comment fa fa-comment',
                        title => $comment_count . ($comment_count != 1 ? ' comments available' : ' comment available')
                      ),
                      ;
                });
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
    $result = 'softfailed' if grep { $_ eq 'workaround' } (@{$screenshot->{properties} || []});
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
