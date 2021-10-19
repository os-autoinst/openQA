# Copyright 2015-2021 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::WebAPI::Plugin::Helpers;
use Mojo::Base 'Mojolicious::Plugin', -signatures;

use Mojo::ByteStream;
use OpenQA::Schema;
use OpenQA::Utils qw(bugurl human_readable_size render_escaped_refs href_to_bugref);
use OpenQA::Events;
use OpenQA::Jobs::Constants qw(EXECUTION_STATES PRE_EXECUTION_STATES);

sub register ($self, $app, $config) {
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
            if ($timedate->days() > 0) {
                sprintf("%d days %02d:%02d hours", $timedate->days(), $timedate->hours(), $timedate->minutes());
            }
            elsif ($timedate->hours() > 0) {
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

    $app->helper(
        bugtitle_for => sub {
            my ($c, $bugid, $bug) = @_;
            my $text = "Bug referenced: $bugid";
            if ($bug && $bug->existing && $bug->title) {
                $text .= "\n" . $bug->title;
            }
            return $text;
        });

    $app->helper(
        bug_report_actions => sub {
            my ($c, %args) = @_;
            return $c->include_branding('external_reporting', %args);
        });

    $app->helper(
        human_readable_size => sub {
            my ($c, $size) = @_;
            return human_readable_size($size);
        });

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
            my ($c, $testid, $file_name, $frametime) = @_;
            my $t = sprintf('&t=%s,%s', $frametime->[0], $frametime->[1]);
            my $url = $c->url_for('video', testid => $testid)->query(filename => $file_name) . $t;
            my $icon = $c->t(i => (class => 'step_action fa fa-file-video-o fa-lg'));
            my $class = 'step_action fa fa-file-video-o fa-lg';
            return $c->link_to($url => (title => 'Jump to video', class => $class) => sub { '' });
        });

    $app->helper(
        rendered_refs_no_shortening => sub {
            my ($c, $text) = @_;
            return render_escaped_refs($text);
        });

    $app->helper(
        current_job_group => sub {
            my ($c) = @_;

            my $job = $c->stash('job') or return;
            my $distri = $c->stash('distri');
            my $build = $c->stash('build');
            my $version = $c->stash('version');
            my $group_id = $job->group_id;
            if (!$group_id && !($distri && $build && $version)) {
                return;
            }

            my %query = (build => $build, distri => $distri, version => $version);
            my $crumbs;
            my $overview_text;
            if ($group_id) {
                $query{groupid} = $group_id;
                $crumbs .= "\n<li id='current-group-overview'>";
                $crumbs
                  .= $c->link_to($c->url_for('group_overview', groupid => $group_id) => (class => 'dropdown-item') =>
                      sub { return $job->group->name . ' (current)' });
                $crumbs .= "</li>";
                $overview_text = 'Build ' . $job->BUILD;
            }
            else {
                $overview_text = "Build $build\@$distri $version";
            }
            my $overview_url = $c->url_for('tests_overview')->query(%query);

            $crumbs .= "\n<li id='current-build-overview'>";
            $crumbs .= $c->link_to($overview_url => (class => 'dropdown-item') =>
                  sub { '<i class="fa fa-arrow-right"></i> ' . $overview_text });
            $crumbs .= "</li>";
            $crumbs .= "\n<li role='separator' class='dropdown-divider'></li>\n";
            return Mojo::ByteStream->new($crumbs);
        });

    $app->helper(current_job => sub { shift->stash('job') });

    $app->helper(is_operator_js => sub { Mojo::ByteStream->new(shift->helpers->is_operator ? 'true' : 'false') });
    $app->helper(is_admin_js => sub { Mojo::ByteStream->new(shift->helpers->is_admin ? 'true' : 'false') });

    $app->helper(
        # Just like 'include', but includes the template with the given
        # name from the correct directory for the 'branding' config setting
        # falls back to 'plain' if brand doesn't include the template, so
        # allowing partial brands
        include_branding => sub {
            my ($c, $name, %args) = @_;
            my $path = "branding/" . $c->app->config->{global}->{branding} . "/$name";
            my $ret = $c->render_to_string($path, %args);
            if (defined($ret)) {
                return $ret;
            }
            else {
                $path = "branding/plain/$name";
                return $c->render_to_string($path, %args);
            }
        });

    $app->helper(
        icon_url => sub {
            my ($c, $icon) = @_;
            my $icon_asset = $c->app->asset->processed($icon)->[0];
            die "Could not find icon '$icon' in assets" unless $icon_asset;
            return $c->url_for(assetpack => $icon_asset->TO_JSON);
        });

    $app->helper(
        favicon_url => sub {
            my ($c, $suffix) = @_;
            return $c->icon_url("logo$suffix") unless my $job = $c->stash('job');
            my $status = $job->status;
            return $c->icon_url("logo-$status$suffix");
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
            return OpenQA::Events->singleton->emit($event, [$user, $self->tx->connection, $event, $data]);
        });

    $app->helper(
        text_with_title => sub {
            my ($c, $text) = @_;
            return $c->tag('span', title => $text, $text);
        });

    my @unfinished_states = (EXECUTION_STATES, PRE_EXECUTION_STATES);
    $app->helper(
        build_progress_bar_section => sub ($c, $key, $res, $max, $params, $class = '') {
            return '' unless $res;
            my $url = $params->{url};
            my $text = "$res $key";
            my $link_or_text = $url
              ? sub {
                $url->query($key eq 'unfinished' ? (state => \@unfinished_states) : (result => $key));
                $c->tag('a', href => $url->query($params->{query_params}), $text);
              }
              : $text;
            return $c->tag(
                'div',
                class => "progress-bar progress-bar-$key $class",
                style => 'width: ' . ($res * 100 / $max) . '%;',
                $link_or_text
            );
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
            return $c->tag(
                'li',
                $c->link_to(
                    $group->name => $c->url_for('group_overview', groupid => $group->id) => class => 'dropdown-item'
                ));
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

    $app->helper(
        render_specific_not_found => sub {
            my ($c, $title, $error_message) = @_;

            $c->stash(
                title => $title,
                error_message => $error_message,
            );
            return $c->render(
                template => 'main/specific_not_found',
                status => 404,
            );
        });

    $app->helper(
        populate_hash_with_needle_timestamps_and_urls => sub {
            my ($c, $needle, $hash) = @_;

            $hash->{last_seen} = $needle ? $needle->last_seen_time || 'never' : 'unknown';
            $hash->{last_match} = $needle ? $needle->last_matched_time || 'never' : 'unknown';
            return $hash unless $needle;
            if (my $last_seen_module_id = $needle->last_seen_module_id) {
                $hash->{last_seen_link} = $c->url_for(
                    'admin_needle_module',
                    module_id => $last_seen_module_id,
                    needle_id => $needle->id
                );
            }
            if (my $last_matched_module_id = $needle->last_matched_module_id) {
                $hash->{last_match_link} = $c->url_for(
                    'admin_needle_module',
                    module_id => $last_matched_module_id,
                    needle_id => $needle->id
                );
            }
            return $hash;
        });

    $app->helper(
        popover_link => sub {
            my ($c, $text, $url) = @_;
            return $text unless $url;
            return "<a href='$url'>$text</a>";
            # note: This code ends up in an HTML attribute and therefore needs to be escaped by the template
            #       rendering. Therefore not using link_to here (which would prevent escaping of the "a" tag).
        });

    $app->helper(
        setting_link => sub {
            my ($c, $uri, $jobid) = @_;
            my $uri_link = $uri =~ m{^https?://} ? $uri : "$jobid/settings/$uri";
            return $c->link_to($uri => $uri_link);
        });

    $app->helper(find_job_or_render_not_found => \&_find_job_or_render_not_found);

    $app->helper(
        'reply.gru_result' => sub {
            my ($c, $result, $error_code) = @_;
            return $c->render(json => $result, status => ($error_code // 200));
        });

    $app->helper('reply.validation_error' => \&_validation_error);

    $app->helper(compose_job_overview_search_args => \&_compose_job_overview_search_args);
    $app->helper(param_hash => \&_param_hash);
    $app->helper(
        link_key_exists => sub {
            my ($c, $value) = @_;
            return exists $c->app->config->{settings_ui_links}->{$value};
        });
}

# returns the search args for the job overview according to the parameter of the specified controller
sub _compose_job_overview_search_args ($c) {
    my %search_args;

    my $v = $c->validation;
    $v->optional('distri', 'not_empty');
    $v->optional('version', 'not_empty');
    $v->optional('flavor', 'not_empty');
    $v->optional('build', 'not_empty');
    $v->optional('test', 'not_empty');
    $v->optional('modules', 'comma_separated', 'not_empty');
    $v->optional('modules_result', 'not_empty');
    $v->optional('module_re', 'not_empty');
    $v->optional('group', 'not_empty');
    $v->optional('groupid', 'not_empty');
    $v->optional('id', 'not_empty');
    $v->optional('limit', 'not_empty')->num(0, undef);

    # add simple query params to search args
    for my $arg (qw(distri version flavor test limit)) {
        next unless $v->is_valid($arg);
        my $params = $v->every_param($arg);
        my $param_count = scalar @$params;
        if ($param_count == 1) {
            $search_args{$arg} = $params->[0];
        }
        elsif ($param_count > 1) {
            $search_args{$arg} = {-in => $params};
        }
    }

    # handle build separately
    my $build = $v->every_param('build');
    $search_args{build} = $build if $build && @$build;

    my $modules = $v->every_param('modules');
    $search_args{modules} = $modules if $modules && @$modules;
    my $result = $v->every_param('modules_result');
    $search_args{modules_result} = $result if $result && @$result;

    # allow filtering by regular expression
    my $regexp = $v->every_param('module_re');
    $search_args{module_re} = shift @$regexp if $regexp && @$regexp;

    # add group query params to search args
    # (By 'every_param' we make sure to use multiple values for groupid and
    # group at the same time as a logical or, i.e. all specified groups are
    # returned.)
    my $schema = $c->schema;
    my @groups;
    if ($v->is_valid('groupid') || $v->is_valid('group')) {
        my @group_id_search = map { {id => $_} } @{$v->every_param('groupid')};
        my @group_name_search = map { {name => $_} } @{$v->every_param('group')};
        my @search_terms = (@group_id_search, @group_name_search);
        @groups = $schema->resultset('JobGroups')->search(\@search_terms)->all;
    }

    # determine build number
    if (!$search_args{build}) {
        if (@groups) {
            my %builds;
            for my $group (@groups) {
                my $last_build = $schema->resultset('Jobs')->latest_build(%search_args, groupid => $group->id) or next;
                $builds{$last_build}++;
            }
            $search_args{build} = [sort keys %builds] if %builds;
        }
        else {
            my $build = $schema->resultset('Jobs')->latest_build(%search_args);
            $search_args{build} = $build if $build;
        }

        # print debug output
        if (@groups == 0) {
            $c->app->log->debug('No build and no group specified, will lookup build based on the other parameters');
        }
        elsif (@groups == 1) {
            $c->app->log->debug('Only one group but no build specified, searching for build');
        }
        else {
            $c->app->log->info('More than one group but no build specified, selecting all latest builds in groups');
        }
    }

    # exclude jobs which are already cloned by setting scope for OpenQA::Jobs::complex_query()
    $search_args{scope} = 'current';

    # allow filtering by job ID
    my $ids = $v->every_param('id');
    $search_args{id} = $ids if $ids && @$ids;
    # note: filter for results, states and failed modules are applied after the initial search
    #       so old jobs are not revealed by applying those filters

    # allow filtering by group ID or group name
    $search_args{groupids} = [map { $_->id } @groups] if @groups;

    return (\%search_args, \@groups);
}

sub _param_hash ($c, $name) {
    my $v = $c->validation;
    $v->optional($name, 'comma_separated', 'not_empty');
    my $values = $v->every_param($name);
    return @$values ? {map { $_ => 1 } @$values} : undef;
}

sub _find_job_or_render_not_found {
    my ($c, $job_id) = @_;

    my $job = $c->schema->resultset('Jobs')->find(int($job_id));
    return $job if $job;
    $c->render(json => {error => 'Job does not exist'}, status => 404);
    return undef;
}

sub _validation_error {
    my ($c, $args) = @_;
    my $format = $args->{format} // 'text';
    my @errors;
    for my $parameter (@{$c->validation->failed}) {
        if (exists $c->validation->input->{$parameter}) {
            push @errors, "$parameter invalid";
        }
        else {
            push @errors, "$parameter missing";
        }
    }
    my $failed = join ', ', @errors;
    my $error = "Erroneous parameters ($failed)";
    return $c->render(json => {error => $error}, status => 400) if $format eq 'json';
    return $c->render(text => $error, status => 400);
}

1;
