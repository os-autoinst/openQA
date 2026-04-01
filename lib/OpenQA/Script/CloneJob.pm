# Copyright 2018-2021 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Script::CloneJob;

use Mojo::Base -strict, -signatures;

use Cpanel::JSON::XS;
use Data::Dump 'pp';
use Exporter 'import';
use OpenQA::Command;
use OpenQA::Jobs::Constants;
use Mojo::File 'path';
use Mojo::URL;
use Mojo::JSON;    # booleans
use OpenQA::Script::CloneJobSUSE;
use List::Util 'any';
use HTTP::Status qw(:constants);

package OpenQA::Script::CloneJob::Command {
    use Mojo::Base 'OpenQA::Command', -signatures;
    sub handle_result ($self, $tx, $orig_tx = undef) { $tx }
}

our @EXPORT = qw(
  clone_jobs
  clone_job_apply_settings
  clone_job_get_job
  clone_job_download_assets
  create_url_handler
  split_jobid
  post_jobs
  openqa_baseurl
);

use constant GLOBAL_SETTINGS => (qw(WORKER_CLASS _GROUP _GROUP_ID));

use constant JOB_SETTING_OVERRIDES => {
    _GROUP => '_GROUP_ID',
    _GROUP_ID => '_GROUP',
};

use constant CURL => $ENV{OPENQA_CLI_CURL_PATH} // 'curl';

my $TEST_NAME = TEST_NAME_ALLOWED_CHARS;
my $TEST_NAME_PLUS_MINUS = TEST_NAME_ALLOWED_CHARS_PLUS_MINUS;
my $SETTINGS_REGEX = qr|([A-Z0-9_]+(\[\])?)(:([$TEST_NAME]+(?:[$TEST_NAME_PLUS_MINUS]+[$TEST_NAME])?))?(\+)?=(.*)|;

sub is_global_setting ($key) {
    any { $key eq $_ } GLOBAL_SETTINGS;
}

sub clone_job_apply_settings ($argv, $depth, $settings, $options) {
    delete $settings->{NAME};    # usually autocreated

    for my $arg (@$argv) {
        # split arg into key and value
        unless ($arg =~ $SETTINGS_REGEX) {
            warn "command-line argument '$arg' is no valid setting and will be ignored\n";
            next;
        }
        my ($key, $scope, $plus, $value) = ($1, $4, $5, $6);
        next if defined $scope && ($settings->{TEST} // '') ne $scope;
        next if !defined $scope && !is_global_setting($key) && $depth > 1 && !$options->{'parental-inheritance'};

        # delete key if value empty
        if (!defined $value || $value eq '') {
            delete $settings->{$key};
            next;
        }

        # allow appending via `+=`
        $value = ($settings->{$key} // '') . $value if $plus;

        # assign value to key, delete overrides
        $settings->{$key} = $value;
        if (my $override = JOB_SETTING_OVERRIDES->{$key}) {
            delete $settings->{$override};
        }
    }
}

sub _handle_unexpected_return_code ($tx) {    # uncoverable statement
    warn sprintf 'unexpected return code: %s %s', $tx->res->code, $tx->res->message;    # uncoverable statement
    exit 1;    # uncoverable statement
}

sub _handle_txn_error ($tx, $jobid, $ctx) {

    if (my $err = $tx->error) {
        $err->{code} //= 'connection error:';
        die "failed to get $ctx '$jobid': $err->{code} $err->{message}";
    }
    _handle_unexpected_return_code($tx) unless $tx->res->code == HTTP_OK;
}

sub _get_with_retry ($url_handler, $url, $jobid, $ctx, $options) {
    my $remote = $url_handler->{remote};
    my $tx = $url_handler->{command}->retry_tx($remote, $remote->build_tx(GET => $url), $options->{retry});
    _handle_txn_error($tx, $jobid, $ctx);
    return $tx->res->json;
}

sub _get_vars ($jobid, $url_handler, $options) {
    my $url = $url_handler->{remote_url}->clone->path("/tests/$jobid/file/vars.json");
    return _get_with_retry($url_handler, $url, $jobid, 'vars.json of job', $options);
}

sub clone_job_get_job ($jobid, $url_handler, $options) {
    my $url = $url_handler->{remote_url}->clone;
    $url->path("jobs/$jobid");
    $url->query->merge(check_assets => 1) unless $options->{'ignore-missing-assets'};
    my $job = _get_with_retry($url_handler, $url, $jobid, 'job', $options)->{job};
    print STDERR Cpanel::JSON::XS->new->pretty->encode($job) if $options->{verbose};
    $job->{vars} = _get_vars($jobid, $url_handler, $options) if $options->{reproduce};
    return $job;
}

sub _job_setting_is ($job, $key, $expected_value) {
    my $actual_value = $job->{settings}->{$key};
    return $actual_value && $actual_value eq $expected_value;
}

sub _get_chained_parents ($job, $url_handler, $options, $parents = [], $parent_ids = {}) {
    next if $parent_ids->{$job->{id}}++;
    my @direct_parents = map { clone_job_get_job($_, $url_handler, $options) } @{$job->{parents}->{Chained}};
    push @$parents, @direct_parents;
    _get_chained_parents($_, $url_handler, $options, $parents, $parent_ids) for @direct_parents;
    return $parents;
}

sub _is_asset_generated_by_cloned_jobs ($job, $parents, $file, $options) {
    return 0 if ($options->{'skip-deps'} || $options->{'skip-chained-deps'}) && (scalar @$parents != 0);
    for my $j (@$parents, $job) {
        for my $setting (qw(PUBLISH_HDD_1 PUBLISH_PFLASH_VARS)) {
            return 1 if _job_setting_is $j, $setting => $file;
        }
    }
    return 0;
}

sub _job_publishes_uefi_vars ($job, $file) {
    $job->{settings}->{UEFI} && _job_setting_is $job, PUBLISH_PFLASH_VARS => $file;
}

sub _check_for_missing_assets ($job, $parents, $options) {
    return undef if $options->{'ignore-missing-assets'};
    my $missing_assets = $job->{missing_assets};
    return undef unless ref $missing_assets eq 'ARRAY';    # most likely an old version of the web UI
    my @relevant_missing_assets;
    for my $missing_asset (@$missing_assets) {
        my ($type, $name) = split qr{/}, $missing_asset, 2;
        push @relevant_missing_assets, $missing_asset
          unless _is_asset_generated_by_cloned_jobs $job, $parents, $name, $options;
    }
    return undef unless @relevant_missing_assets;
    my $relevant_missing_assets = join "\n - ", @relevant_missing_assets;
    my $note = 'Use --ignore-missing-assets or --skip-download to proceed regardless.';
    die "The following assets are missing:\n - $relevant_missing_assets\n$note\n";
}

sub _format_cmd_error ($command) {
    return "Failed to execute '$command': $!" if $? == -1;
    return ($? & 127)
      ? sprintf "'$command' received signal %d", $? & 127
      : sprintf "'$command' exited with non-zero exit status %d", $? >> 8;
}

sub _run_cmd ($command, @args) { system $command, @args; return $? == 0 ? '' : _format_cmd_error($command) }

sub _url_from_cmd ($command, @args) {    # use open (and not qx) to avoid splitting arguments or using a shell
    open my $fh, '-|', $command, @args or return "Failed to execute '$command': $!";
    my $out = do { local $/; <$fh> };
    close $fh;
    return $? == 0 ? Mojo::URL->new($out) : _format_cmd_error($command);
}

sub _args_for_header ($headers, $name) {
    return (map { ('-H', "$name: $_") } @{$headers->every_header($name)});
}

sub _auth_args ($from, $secrets) {
    my $headers = Mojo::Headers->new;
    OpenQA::UserAgent::add_auth_headers($headers, $from, @$secrets) if $secrets;
    return [map { _args_for_header $headers, $_ } @{$headers->names}];
}

sub _resolve_redirection ($from, $curl_args, $secrets) {
    my @effective_url_args = qw(--silent --location --head --output /dev/null -w %{url_effective});
    return _url_from_cmd CURL, @$curl_args, @{_auth_args($from, $secrets)}, @effective_url_args, $from;
}

sub mirror ($url_handler, $from, $dst) {
    my ($curl_args, $secrets) = ($url_handler->{curl_args}, $url_handler->{secrets});
    return $from if ref($from = _resolve_redirection $from, $curl_args, $secrets) ne 'Mojo::URL';
    return _run_cmd CURL, @$curl_args, @{_auth_args($from, $secrets)}, qw(--continue-at - --output), $dst, $from;
}

sub clone_job_download_assets ($jobid, $job, $url_handler, $options) {
    my $parents = _get_chained_parents($job, $url_handler, $options);
    _check_for_missing_assets($job, $parents, $options);
    my $remote_url = $url_handler->{remote_url};
    for my $type (keys %{$job->{assets}}) {
        next if $type eq 'repo';    # we can't download repos
        for my $file (@{$job->{assets}->{$type}}) {
            my $dst = $file;
            # skip downloading published assets if we are also cloning the generation job or
            # if the only cloned job *is* the generation job
            next if _is_asset_generated_by_cloned_jobs $job, $parents, $file, $options;
            # skip downloading "uefi-vars" assets if not actually generated by
            # any parent
            if ($file =~ qr/uefi-vars/) {
                my $parent_publishes_uefi_vars;
                $parent_publishes_uefi_vars = _job_publishes_uefi_vars $_, $file and last for @$parents;
                next unless $parent_publishes_uefi_vars;
            }
            $dst =~ s,.*/,,;
            my $dst_dir = path($options->{dir}, $type)->make_path;
            $dst = $dst_dir->child($dst)->to_string;
            die "Cannot write $dst_dir\n" unless -w $dst_dir;
            my $from = $remote_url->clone;
            $from->path(sprintf '/tests/%d/asset/%s/%s', $jobid, $type, $file);
            print STDERR "downloading\n$from\nto\n$dst\n";
            if (my $error = mirror($url_handler, $from, $dst)) {
                my $msg = "\nCloning aborted during asset download: $error\n";
                $options->{'ignore-missing-assets'} ? print STDERR $msg : die $msg;
            }

            # ensure the asset cleanup preserves the asset the configured amount of days starting from the time
            # it has been cloned (otherwise old assets might be cleaned up directly again after cloning)
            path($dst)->touch;
        }
    }
}

sub split_jobid ($url_string) {
    # handle scheme being omitted and support specifying only a domain (e.g. 'openqa.opensuse.org')
    $url_string = "http://$url_string" unless $url_string =~ m{https?://};
    my $url = Mojo::URL->new($url_string);

    $url->host($url->path->parts->[0]) unless $url->host;

    my $host_url = Mojo::URL->new->scheme($url->scheme)->host($url->host)->port($url->port)->to_string;
    (my $jobid) = $url->path =~ /([0-9]+)/;
    return ($host_url, $jobid);
}

sub make_curl_arguments ($options) {
    my @args = ('--retry', $options->{retry}, '--retry-connrefused');
    push @args, '--no-progress-meter' unless $options->{'show-progress'};
    push @args, '--verbose' if $options->{verbose};
    return \@args;
}

sub read_secrets ($host) {
    return undef unless my $cfg = OpenQA::UserAgent::open_config_file($host);
    my $apikey = ($cfg->val($host, 'key'))[-1];
    my $apisecret = ($cfg->val($host, 'secret'))[-1];
    return $apikey && $apisecret ? [$apikey, $apisecret] : undef;
}

sub create_url_handler ($options) {
    # configure user agent for destination host (usually localhost)
    my $local_url = OpenQA::Client::url_from_host($options->{host});
    $local_url->path('/api/v1/jobs');
    my $command = OpenQA::Script::CloneJob::Command->new(
        name => 'openqa-clone-job',
        apikey => $options->{apikey},
        apisecret => $options->{apisecret},
        options => $options
    );
    my $local = $command->client($local_url)->max_redirects(3);
    die "API key/secret for '$options->{host}' missing. Check out '$0 --help' for the config file syntax/lookup.\n"
      if !$options->{'export-command'} && !($local->apikey && $local->apisecret);

    # configure the default for the number of retries and use exponential backoff by default
    $options->{retry} //= 5;
    $ENV{OPENQA_CLI_RETRY_FACTOR} //= 2;

    # configure user agents for the source host (usually a remote host)
    my $remote_url = OpenQA::Client::url_from_host($options->{from});
    $remote_url->path('/api/v1/jobs');
    return {
        curl_args => make_curl_arguments($options),
        secrets => read_secrets($remote_url->host),
        command => $command,
        local => $local,
        local_url => $local_url,
        remote => $command->client($remote_url)->apikey(undef)->apisecret(undef)->max_redirects(3),
        remote_url => $remote_url
    };
}

sub openqa_baseurl ($local_url) {
    my $port = '';
    if (
        $local_url->port
        && (   ($local_url->scheme eq 'http' && $local_url->port != 80)
            || ($local_url->scheme eq 'https' && $local_url->port != 443)))
    {
        $port = ':' . $local_url->port;
    }
    return $local_url->scheme . '://' . $local_url->host . $port;
}

sub get_deps ($job, $job_type) {
    my $deps = $job->{$job_type};
    return ($deps->{Chained} // [], $deps->{'Directly chained'} // [], $deps->{Parallel} // []);
}

sub handle_tx ($tx, $url_handler, $options, $jobs) {
    my $res = $tx->res;
    my $json = $res->json;
    if (!$tx->error && ref $json eq 'HASH' && ref $json->{ids} eq 'HASH') {
        my $cloned_jobs = $json->{ids};
        print Cpanel::JSON::XS->new->pretty->encode($cloned_jobs) and return $cloned_jobs if $options->{'json-output'};
        if (my $job_count = keys %$cloned_jobs) {
            my $base_url = openqa_baseurl($url_handler->{local_url});
            say $job_count == 1 ? '1 job has been created:' : "$job_count jobs have been created:";
            say " - $jobs->{$_}->{name} -> $base_url/tests/$cloned_jobs->{$_}" for sort keys %$cloned_jobs;
        }
        return $cloned_jobs;
    }
    elsif (my $body = $res->body) {
        die 'Failed to create job, server replied: ', pp(ref $json ? $json : $body), "\n";
    }
    else {
        die "Failed to create job, empty response. Make sure your HTTP proxy is running, e.g. apache, nginx, etc.\n";
    }
}

# append a formatted "-NN" to the TEST parameter for each job being posted
sub append_idx_to_test_name ($n, $digits, $post_params) {
    my $suffix = sprintf "-%0${digits}d", $n;
    foreach my $job_key (keys %$post_params) {
        my $job = $post_params->{$job_key};
        if ($n == 1) {
            $job->{TEST} .= $suffix;    # just append at the first time
        }
        else {
            # from the second onwards, replace old with the new number
            $job->{TEST} =~ s/-\d+$/$suffix/;
        }
    }
}

sub clone_jobs ($jobid, $options) {
    my $url_handler = create_url_handler($options);
    my $repeat = delete $options->{repeat} || 1;
    my $digits = length $repeat;
    clone_job($jobid, $url_handler, $options, my $post_params = {}, my $jobs = {});
    for my $counter (1 .. $repeat) {
        append_idx_to_test_name($counter, $digits, $post_params) if $repeat > 1;
        if (my $tx = post_jobs($post_params, $url_handler, $options)) {
            $tx = $url_handler->{command}->retry_tx($url_handler->{local}, $tx, $options->{retry});
            handle_tx($tx, $url_handler, $options, $jobs);
        }
    }
}

sub _add_setting ($settings, $vars, $var, $key, $for) {
    $settings->{$key} = $vars->{$var} or die "unable to preserve $for ref, original job lacks $var\n";
}

sub _add_versioning_settings ($settings, $vars) {
    _add_setting($settings, $vars, qw(TEST_GIT_URL CASEDIR CASEDIR));
    _add_setting($settings, $vars, qw(TEST_GIT_HASH TEST_GIT_REFSPEC CASEDIR));
    _add_setting($settings, $vars, qw(NEEDLES_GIT_URL NEEDLES_DIR NEEDLES_DIR));
    _add_setting($settings, $vars, qw(NEEDLES_GIT_HASH NEEDLES_GIT_REFSPEC NEEDLES_DIR));
}

sub clone_job ($jobid, $url_handler, $options, $post_params = {}, $jobs = {}, $depth = 1, $relation = '') {
    return if defined $post_params->{$jobid};

    my $job = $jobs->{$jobid} = clone_job_get_job($jobid, $url_handler, $options);

    my $settings = $post_params->{$jobid} = {%{$job->{settings}}};
    _add_versioning_settings($settings, $job->{vars}) if $options->{reproduce};
    my $clone_children = $options->{'clone-children'};
    my $max_depth = $options->{'max-depth'} // 1;
    for my $job_type (qw(parents children)) {
        next unless $job->{$job_type};

        my ($chained, $directly_chained, $parallel) = get_deps($job, $job_type);
        print STDERR "Cloning $job_type of $job->{name}\n"
          if !$options->{'json-output'} && (@$chained || @$directly_chained || @$parallel);


        for my $dependencies ($chained, $directly_chained, $parallel) {
            # constrain cloning parents according to specified options
            if ($job_type eq 'parents') {
                my $is_chained = $dependencies == $chained || $dependencies == $directly_chained;
                next if $options->{'skip-deps'} || ($options->{'skip-chained-deps'} && $is_chained);
            }
            # constrain cloning children according to specified options
            elsif ($job_type eq 'children') {
                next if $max_depth && $depth > $max_depth;
                next unless $clone_children || $dependencies == $parallel;
            }

            clone_job($_, $url_handler, $options, $post_params, $jobs, $depth + 1, $job_type) for @$dependencies;
        }
        if ($job_type eq 'parents') {
            _assign_existing_dependencies('_PARALLEL', $parallel, $settings, $jobs);
            _assign_existing_dependencies('_START_AFTER', $chained, $settings, $jobs);
            _assign_existing_dependencies('_START_DIRECTLY_AFTER', $directly_chained, $settings, $jobs);
        }
    }
    $settings->{CLONED_FROM} = $url_handler->{remote_url}->clone->path("/tests/$jobid")->to_string;
    if (my $group_id = $job->{group_id}) { $settings->{_GROUP_ID} = $group_id }
    clone_job_apply_settings($options->{args}, $relation eq 'children' ? 0 : $depth, $settings, $options);
    OpenQA::Script::CloneJobSUSE::detect_maintenance_update($jobid, $url_handler, $settings)
      if $options->{'check-repos'};
    clone_job_download_assets($jobid, $job, $url_handler, $options) unless $options->{'skip-download'};
}

sub _assign_existing_dependencies ($name, $deps, $settings, $jobs) {
    return unless my @filtered = grep { $jobs->{$_} } @$deps;
    $settings->{$name} = join ',', @filtered;
}

sub post_jobs ($post_params, $url_handler, $options) {
    my %composed_params = map {
        my $job_id = $_;
        my $params_for_job = $post_params->{$job_id};
        map { my $key = "$_:$job_id"; $key => $params_for_job->{$_} } keys %$params_for_job
    } keys %$post_params;
    $composed_params{is_clone_job} = 1;    # used to figure out if this is a clone operation
    my ($local, $local_url) = ($url_handler->{local}, $url_handler->{local_url}->clone);
    if ($options->{'export-command'}) {
        $local_url->path(Mojo::Path->new);
        print "openqa-cli api --host '$local_url' -X POST jobs ";
        say join ' ', map { "'$_=$composed_params{$_ }'" } sort keys %composed_params;
        return undef;
    }
    print STDERR Cpanel::JSON::XS->new->pretty->encode(\%composed_params) if $options->{verbose};
    return $local->build_tx(POST => $local_url, form => \%composed_params);
}

1;
