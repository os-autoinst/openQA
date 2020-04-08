# Copyright (C) 2020 SUSE LLC
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
# You should have received a copy of the GNU General Public License

package OpenQA::Log;

use strict;
use warnings;

use Carp;
use Exporter 'import';
use Mojo::File 'path';
use File::Path 'make_path';
use OpenQA::App;
use Time::HiRes 'gettimeofday';
use POSIX 'strftime';
use File::Spec::Functions 'catfile';
use Sys::Hostname;

our $VERSION   = '0.0.1';
our @EXPORT_OK = qw(
  log_debug
  log_warning
  log_info
  log_error
  log_fatal
  add_log_channel
  remove_log_channel
  log_format_callback
  get_channel_handle
  setup_log
);

my %CHANNELS;
my %LOG_DEFAULTS = (LOG_TO_STANDARD_CHANNEL => 1, CHANNELS => []);

sub log_warning;

# logging helpers - _log_msg wrappers

# log_debug("message"[, param1=>val1, param2=>val2]);
# please check the _log_msg function for a brief description of the accepted params
# examples:
#  log_debug("message");
#  log_debug("message", channels=>'channel1')
#  log_debug("message", channels=>'channel1', standard=>0)
sub log_debug { _log_msg('debug', @_); }

# log_info("message"[, param1=>val1, param2=>val2]);
sub log_info { _log_msg('info', @_); }

# log_warning("message"[, param1=>val1, param2=>val2]);
sub log_warning { _log_msg('warn', @_); }

# log_error("message"[, param1=>val1, param2=>val2]);
sub log_error { _log_msg('error', @_); }
# log_fatal("message"[, param1=>val1, param2=>val2]);
sub log_fatal {
    _log_msg('fatal', @_);
    croak $_[0];
}

sub _current_log_level {
    my $app = OpenQA::App->singleton;
    return defined $app && $app->can('log') && $app->log->can('level') && $app->log->level;
}

# The %options parameter is used to control which destinations the message should go.
# Accepted parameters: channels, standard.
#  - channels. Scalar or a arrayref containing the name of the channels to log to.
#  - standard. Boolean to indicate if it should use the *defaults* to log.
#
# If any of parameters above don't exist, this function will log to the defaults (by
# default it is $app). The standard option need to be set to true. Please check the function
# add_log_channel to learn on how to set a channel as default.
sub _log_msg {
    my ($level, $msg, %options) = @_;

    # use default options
    if (!%options) {
        return _log_msg(
            $level, $msg,
            channels => $LOG_DEFAULTS{CHANNELS},
            standard => $LOG_DEFAULTS{LOG_TO_STANDARD_CHANNEL});
    }

    # prepend process ID on debug level
    if (_current_log_level eq 'debug') {
        $msg = "[pid:$$] $msg";
    }

    # log to channels
    my $wrote_to_at_least_one_channel = 0;
    if (my $channels = $options{channels}) {
        for my $channel (ref($channels) eq 'ARRAY' ? @$channels : $channels) {
            $wrote_to_at_least_one_channel |= _log_to_channel_by_name($level, $msg, $channel);
        }
    }

    # log to standard (as fallback or when explicitely requested)
    if (!$wrote_to_at_least_one_channel || ($options{standard} // $LOG_DEFAULTS{LOG_TO_STANDARD_CHANNEL})) {
        # use Mojolicious app if available and otherwise just STDERR/STDOUT
        _log_via_mojo_app($level, $msg) or _log_to_stderr_or_stdout($level, $msg);
    }
}

sub _log_to_channel_by_name {
    my ($level, $msg, $channel_name) = @_;

    return 0 unless ($channel_name);
    my $channel = $CHANNELS{$channel_name} or return 0;
    return _try_logging_to_channel($level, $msg, $channel);
}

sub _log_via_mojo_app {
    my ($level, $msg) = @_;

    return 0 unless my $app = OpenQA::App->singleton;
    return 0 unless my $log = $app->log;
    return _try_logging_to_channel($level, $msg, $log);
}

sub _try_logging_to_channel {
    my ($level, $msg, $channel) = @_;

    eval { $channel->$level($msg); };
    return ($@ ? 0 : 1);
}

sub _log_to_stderr_or_stdout {
    my ($level, $msg) = @_;
    if ($level =~ /warn|error|fatal/) {
        STDERR->printflush("[@{[uc $level]}] $msg\n");
    }
    else {
        STDOUT->printflush("[@{[uc $level]}] $msg\n");
    }
}

# When a developer wants to log constantly to a channel he can either constantly pass the parameter
# 'channels' in the log_* functions, or when creating the channel, pass the parameter 'default'.
# This parameter can have two values:
# - "append". This value will append the channel to the defaults, so the simple call to the log_*
#   functions will try to log to the channels set as default.
# - "set". This value will replace all the defaults with the channel being created.
#
# All the parameters set in %options are passed to the Mojo::Log constructor.
sub add_log_channel {
    my ($channel, %options) = @_;
    if ($options{default}) {
        if ($options{default} eq 'append') {
            push @{$LOG_DEFAULTS{CHANNELS}}, $channel;
        }
        elsif ($options{default} eq 'set') {
            $LOG_DEFAULTS{CHANNELS}                = [$channel];
            $LOG_DEFAULTS{LOG_TO_STANDARD_CHANNEL} = 0;
        }
        delete $options{default};
    }
    $CHANNELS{$channel} = Mojo::Log->new(%options);

    $CHANNELS{$channel}->format(\&log_format_callback);
}

# The default format for logging
sub log_format_callback {
    my ($time, $level, @lines) = @_;
    # Unfortunately $time doesn't have the precision we want. So we need to use Time::HiRes
    $time = gettimeofday;
    return
      sprintf(strftime("[%FT%T.%%04d %Z] [$level] ", localtime($time)), 1000 * ($time - int($time)))
      . join("\n", @lines, '');
}

# Removes a channel from defaults.
sub _remove_channel_from_defaults {
    my ($channel) = @_;
    $LOG_DEFAULTS{CHANNELS}                = [grep { $_ ne $channel } @{$LOG_DEFAULTS{CHANNELS}}];
    $LOG_DEFAULTS{LOG_TO_STANDARD_CHANNEL} = 1 if !@{$LOG_DEFAULTS{CHANNELS}};
}

sub remove_log_channel {
    my ($channel) = @_;
    _remove_channel_from_defaults($channel);
    delete $CHANNELS{$channel} if $channel;
}

sub get_channel_handle {
    my ($channel) = @_;
    if ($channel) {
        return $CHANNELS{$channel}->handle if $CHANNELS{$channel};
    }
    elsif (my $app = OpenQA::App->singleton) {
        return $app->log->handle;
    }
    return undef;
}

sub setup_log {
    my ($app, $logfile, $logdir, $level, $log) = @_;

    if ($logdir) {
        make_path($logdir) unless -e $logdir;
        die 'Please point the logs to a valid folder!' unless -d $logdir;
    }

    $level //= $app->config->{logging}->{level} // 'info';
    $logfile = $ENV{OPENQA_LOGFILE} || $app->config->{logging}->{file};

    if ($logfile && $logdir) {
        $logfile = catfile($logdir, $logfile);
        $log     = Mojo::Log->new(
            handle => path($logfile)->open('>>'),
            level  => $app->level,
            format => \&log_format_callback
        );
    }
    elsif ($logfile) {
        $log = Mojo::Log->new(
            handle => path($logfile)->open('>>'),
            level  => $level,
            format => \&log_format_callback
        );
    }
    elsif ($logdir) {
        # So each worker from each host get its own log (as the folder can be shared).
        # Hopefully the machine hostname is already sanitized. Otherwise we need to check
        $logfile
          = catfile($logdir, hostname() . (defined $app->instance ? "-${\$app->instance}" : '') . ".log");
        $log = Mojo::Log->new(
            handle => path($logfile)->open('>>'),
            level  => $app->level,
            format => \&log_format_callback
        );
    }
    else {
        $log = Mojo::Log->new(
            handle => \*STDOUT,
            level  => $level,
            format => sub {
                my ($time, $level, @lines) = @_;
                return "[$level] " . join "\n", @lines, '';
            });
    }

    $app->log($log);
    if ($ENV{OPENQA_SQL_DEBUG} // $app->config->{logging}->{sql_debug} // 'false' eq 'true') {
        require OpenQA::Schema::Profiler;
        # avoid enabling the SQL debug unless we really want to see it
        # it's rather expensive
        OpenQA::Schema::Profiler->enable_sql_debugging;
    }

    OpenQA::App->set_singleton($app);
}

1;
