# Copyright 2020-2021 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Log;

use Mojo::Base -strict, -signatures;

use Carp;
use Exporter 'import';
use Mojo::File 'path';
use File::Path 'make_path';
use OpenQA::App;
use Time::Moment;
use File::Spec::Functions 'catfile';
use Sys::Hostname;

our $VERSION = '0.0.1';
our @EXPORT_OK = qw(
  log_debug
  log_trace
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

# logging helpers - _log_msg wrappers

# log_debug("message"[, param1=>val1, param2=>val2]);
# please check the _log_msg function for a brief description of the accepted params
# examples:
#  log_debug("message");
#  log_debug("message", channels=>'channel1')
#  log_debug("message", channels=>'channel1', standard=>0)
sub log_debug(@) { _log_msg('debug', @_); }

# log_trace("message"[, param1=>val1, param2=>val2]);
sub log_trace(@) { _log_msg('trace', @_); }

# log_info("message"[, param1=>val1, param2=>val2]);
sub log_info(@) { _log_msg('info', @_); }

# log_warning("message"[, param1=>val1, param2=>val2]);
sub log_warning(@) { _log_msg('warn', @_); }

# log_error("message"[, param1=>val1, param2=>val2]);
sub log_error(@) { _log_msg('error', @_); }
# log_fatal("message"[, param1=>val1, param2=>val2]);
sub log_fatal(@) {
    _log_msg('fatal', @_);
    croak $_[0];
}

sub _current_log_level() {
    my $app = OpenQA::App->singleton;
    return 0 unless defined $app && $app->can('log');
    return 0 unless my $log = $app->log;
    return $log->can('level') && $log->level;
}

# The %options parameter is used to control which destinations the message should go.
# Accepted parameters: channels, standard.
#  - channels. Scalar or a arrayref containing the name of the channels to log to.
#  - standard. Boolean to indicate if it should use the *defaults* to log.
#
# If any of parameters above don't exist, this function will log to the defaults (by
# default it is $app). The standard option need to be set to true. Please check the function
# add_log_channel to learn on how to set a channel as default.
sub _log_msg ($level, $msg, %options) {
    # use default options
    return _log_msg(
        $level, $msg,
        channels => $LOG_DEFAULTS{CHANNELS},
        standard => $LOG_DEFAULTS{LOG_TO_STANDARD_CHANNEL}) unless %options;

    # prepend process ID on debug level
    $msg = "[pid:$$] $msg" if _current_log_level eq 'debug';

    # log to channels
    my $wrote_to_at_least_one_channel = 0;
    if (my $channels = $options{channels}) {
        for my $channel (ref($channels) eq 'ARRAY' ? @$channels : $channels) {
            $wrote_to_at_least_one_channel |= _log_to_channel_by_name($level, $msg, $channel);
        }
    }

    # log to standard (as fallback or when explicitly requested)
    # use Mojolicious app if available and otherwise just STDERR/STDOUT
    _log_via_mojo_app($level, $msg)
      or _log_to_stderr_or_stdout($level, $msg)
      if !$wrote_to_at_least_one_channel || ($options{standard} // $LOG_DEFAULTS{LOG_TO_STANDARD_CHANNEL});
}

sub _log_to_channel_by_name ($level, $msg, $channel_name) {
    return 0 unless ($channel_name);
    my $channel = $CHANNELS{$channel_name} or return 0;
    return _try_logging_to_channel($level, $msg, $channel);
}

sub _log_via_mojo_app ($level, $msg) {
    return 0 unless my $app = OpenQA::App->singleton;
    return 0 unless my $log = $app->log;
    return _try_logging_to_channel($level, $msg, $log);
}

sub _try_logging_to_channel ($level, $msg, $channel) {
    eval { $channel->$level($msg); };
    return ($@ ? 0 : 1);
}

sub _log_to_stderr_or_stdout ($level, $msg) {
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
sub add_log_channel ($channel, %options) {
    if ($options{default}) {
        if ($options{default} eq 'append') {
            push @{$LOG_DEFAULTS{CHANNELS}}, $channel;
        }
        elsif ($options{default} eq 'set') {
            $LOG_DEFAULTS{CHANNELS} = [$channel];
            $LOG_DEFAULTS{LOG_TO_STANDARD_CHANNEL} = 0;
        }
        delete $options{default};
    }
    $CHANNELS{$channel} = Mojo::Log->new(%options);
    $CHANNELS{$channel}->format(\&log_format_callback);
}

# The default format for logging
sub log_format_callback ($time, $level, @lines) { '[' . Time::Moment->now . "] [$level] " . join(' ', @lines) . "\n" }

# Removes a channel from defaults.
sub _remove_channel_from_defaults ($channel) {
    $LOG_DEFAULTS{CHANNELS} = [grep { $_ ne $channel } @{$LOG_DEFAULTS{CHANNELS}}];
    $LOG_DEFAULTS{LOG_TO_STANDARD_CHANNEL} = 1 if !@{$LOG_DEFAULTS{CHANNELS}};
}

sub remove_log_channel ($channel) {
    _remove_channel_from_defaults($channel);
    delete $CHANNELS{$channel} if $channel;
}

sub get_channel_handle ($channel = undef) {
    return $CHANNELS{$channel} ? $CHANNELS{$channel}->handle : undef if $channel;
    return undef unless my $app = OpenQA::App->singleton;
    return $app->log->handle;
}

sub setup_log ($app, $logfile = undef, $logdir = undef, $level = undef) {
    if ($logdir) {
        make_path($logdir) unless -e $logdir;
        die 'Please point the logs to a valid folder!' unless -d $logdir;
    }

    $level //= $app->config->{logging}->{level} // 'info';
    $logfile = $ENV{OPENQA_LOGFILE} || $app->config->{logging}->{file};

    my %settings = (level => $level);

    my $log;
    if ($logfile || $logdir) {
        $logfile = catfile($logdir, $logfile) if $logfile && $logdir;
        # So each worker from each host get its own log (as the folder can be shared).
        # Hopefully the machine hostname is already sanitized. Otherwise we need to check
        $logfile //= catfile($logdir, hostname() . (defined $app->instance ? "-${\$app->instance}" : '') . ".log");
        $log = Mojo::Log->new(%settings, handle => path($logfile)->open('>>'));
        $log->format(\&log_format_callback);
    }
    else {
        $log = Mojo::Log->new(%settings, handle => \*STDOUT);
        $log->format(sub ($time, $level, @parts) { "[$level] " . join(' ', @parts) . "\n" });
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
