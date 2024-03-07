# Copyright 2019 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Git;

use Mojo::Base -base, -signatures;
use Cwd 'abs_path';
use OpenQA::Utils qw(run_cmd_with_log_return_error);

has 'app';
has 'dir';
has 'user';

sub enabled ($self, $args = undef) {
    die 'no app assigned' unless my $app = $self->app;
    return ($app->config->{global}->{scm} || '') eq 'git';
}

sub config ($self, $args = undef) {
    die 'no app assigned' unless my $app = $self->app;
    return $app->config->{'scm git'};
}

sub _prepare_git_command ($self, $args = undef) {
    my $dir = $args->{dir} // $self->dir;
    if ($dir !~ /^\//) {
        my $absolute_path = abs_path($dir);
        $dir = $absolute_path if ($absolute_path);
    }
    return ('git', '-C', $dir);
}

sub _format_git_error ($result, $error_message) {
    if ($result->{stderr} or $result->{stdout}) {
        $error_message .= ': ' . $result->{stdout} . $result->{stderr};
    }
    return $error_message;
}

sub _validate_attributes ($self) {
    for my $mandatory_property (qw(app dir user)) {
        die "no $mandatory_property specified" unless $self->$mandatory_property();
    }
}

sub set_to_latest_master ($self, $args = undef) {
    $self->_validate_attributes;

    my @git = $self->_prepare_git_command($args);

    if (my $update_remote = $self->config->{update_remote}) {
        my $res = run_cmd_with_log_return_error([@git, 'remote', 'update', $update_remote]);
        return _format_git_error($res, 'Unable to fetch from origin master') unless $res->{status};
    }

    if (my $update_branch = $self->config->{update_branch}) {
        if ($self->config->{do_cleanup} eq 'yes') {
            my $res = run_cmd_with_log_return_error([@git, 'reset', '--hard', 'HEAD']);
            return _format_git_error($res, 'Unable to reset repository to HEAD') unless $res->{status};
        }
        my $res = run_cmd_with_log_return_error([@git, 'rebase', $update_branch]);
        return _format_git_error($res, 'Unable to reset repository to origin/master') unless $res->{status};
    }

    return undef;
}

sub commit ($self, $args = undef) {
    $self->_validate_attributes;

    my @git = $self->_prepare_git_command($args);
    my @files;

    # stage changes
    for my $cmd (qw(add rm)) {
        next unless $args->{$cmd};
        push(@files, @{$args->{$cmd}});
        my $res = run_cmd_with_log_return_error([@git, $cmd, @{$args->{$cmd}}]);
        return _format_git_error($res, "Unable to $cmd via Git") unless $res->{status};
    }

    # commit changes
    my $message = $args->{message};
    my $author = sprintf('--author=%s <%s>', $self->user->fullname, $self->user->email);
    my $res = run_cmd_with_log_return_error([@git, 'commit', '-q', '-m', $message, $author, @files]);
    return _format_git_error($res, 'Unable to commit via Git') unless $res->{status};

    # push changes
    if (($self->config->{do_push} || '') eq 'yes') {
        $res = run_cmd_with_log_return_error([@git, 'push']);
        return _format_git_error($res, 'Unable to push Git commit') unless $res->{status};
    }

    return undef;
}

sub cache_ref($self, $ref, $relative_path, $output_file) {
    return undef if -f $output_file;
    my @git = $self->_prepare_git_command;
    my $res = run_cmd_with_log_return_error [@git, 'show', "$ref:./$relative_path"], output_file => $output_file;
    return undef if $res->{status};
    unlink $output_file;
    return _format_git_error($res, 'Unable to cache Git ref');
}

1;
