# Copyright 2012-2021 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Utils;
use Mojo::Base -strict, -signatures;

use Carp;
use Cwd 'abs_path';
use Filesys::Df qw(df);
use IPC::Run();
use Mojo::URL;
use Regexp::Common 'URI';
use Time::Seconds;
use Feature::Compat::Try;
use Mojo::File 'path';
use IO::Handle;
use IO::Socket::IP;
use POSIX 'strftime';
use Scalar::Util 'blessed';
use Mojo::Log;
use Scalar::Util qw(blessed reftype looks_like_number);
use Exporter 'import';
use OpenQA::App;
use OpenQA::Constants qw(VIDEO_FILE_NAME_START VIDEO_FILE_NAME_REGEX FRAGMENT_REGEX);
use OpenQA::Log qw(log_info log_debug log_warning log_error);
use Config::Tiny;
use Time::HiRes qw(tv_interval);
use File::Basename;
use File::Spec;
use File::Spec::Functions qw(catfile catdir);
use Fcntl;
use Feature::Compat::Try;
use Mojo::JSON qw(encode_json decode_json);
use Mojo::Util 'xml_escape';
use List::Util qw(min);

my $FRAG_REGEX = FRAGMENT_REGEX;

my (%BUGREFS, %BUGURLS, $MARKER_REFS, $MARKER_URLS, $BUGREF_REGEX);

BEGIN {
    %BUGREFS = (
        bnc => 'https://bugzilla.suse.com/show_bug.cgi?id=',
        bsc => 'https://bugzilla.suse.com/show_bug.cgi?id=',
        boo => 'https://bugzilla.opensuse.org/show_bug.cgi?id=',
        bgo => 'https://bugzilla.gnome.org/show_bug.cgi?id=',
        bmo => 'https://bugzilla.mozilla.org/show_bug.cgi?id=',
        brc => 'https://bugzilla.redhat.com/show_bug.cgi?id=',
        bko => 'https://bugzilla.kernel.org/show_bug.cgi?id=',
        poo => 'https://progress.opensuse.org/issues/',
        gh => 'https://github.com/',
        kde => 'https://bugs.kde.org/show_bug.cgi?id=',
        fdo => 'https://bugs.freedesktop.org/show_bug.cgi?id=',
        jsc => 'https://jira.suse.com/browse/',
        pio => 'https://pagure.io/',
        ggo => 'https://gitlab.gnome.org/',
        gfs => 'https://gitlab.com/fedora/sigs/',
    );
    %BUGURLS = (
        'https://bugzilla.novell.com/show_bug.cgi?id=' => 'bsc',
        $BUGREFS{bsc} => 'bsc',
        $BUGREFS{boo} => 'boo',
        $BUGREFS{bgo} => 'bgo',
        $BUGREFS{bmo} => 'bmo',
        $BUGREFS{brc} => 'brc',
        $BUGREFS{bko} => 'bko',
        $BUGREFS{poo} => 'poo',
        $BUGREFS{gh} => 'gh',
        $BUGREFS{kde} => 'kde',
        $BUGREFS{fdo} => 'fdo',
        $BUGREFS{jsc} => 'jsc',
        $BUGREFS{pio} => 'pio',
        $BUGREFS{ggo} => 'ggo',
        $BUGREFS{gfs} => 'gfs',
    );

    $MARKER_REFS = join('|', keys %BUGREFS);
    $MARKER_URLS = join('|', keys %BUGURLS);

    # <marker>[#<project/repo>]#<id>
    $BUGREF_REGEX = qr{(?<match>(?<marker>$MARKER_REFS)\#?(?<repo>[^#\s<>,]+)?\#(?<id>([A-Z]+-)?\d+))};
}

use constant UNCONSTRAINED_BUGREF_REGEX => $BUGREF_REGEX;
use constant BUGREF_REGEX => qr{(?:^|(?<=<p>)|(?<=\s|,))$BUGREF_REGEX(?![\w\"])};
use constant LABEL_REGEX => qr/\blabel:(?<match>([\w:#]+))\b/;
use constant FLAG_REGEX => qr/\bflag:(?<match>([\w:#]+))\b/;

use constant ONE_SECOND_IN_MICROSECONDS => 1_000_000;
use constant RANDOM_STRING_DEFAULT_LENGTH => 16;

our $VERSION = sprintf '%d.%03d', q$Revision: 1.12 $ =~ /(\d+)/g;
our @EXPORT = qw(
  UNCONSTRAINED_BUGREF_REGEX
  BUGREF_REGEX
  LABEL_REGEX
  FLAG_REGEX
  needledir
  productdir
  testcasedir
  gitrepodir
  is_in_tests
  save_base64_png
  run_cmd_with_log
  run_cmd_with_log_return_error
  parse_assets_from_settings
  find_labels
  find_flags
  find_bugref
  find_bugrefs
  bugurl
  bugref_to_href
  href_to_bugref
  url_to_href
  find_bug_number
  render_escaped_refs
  asset_type_from_setting
  check_download_url
  check_download_passlist
  get_url_short
  create_downloads_list
  create_git_clone_list
  human_readable_size
  locate_asset
  detect_current_version
  parse_tags_from_comments
  path_to_class
  loaded_modules
  loaded_plugins
  hashwalker
  read_test_modules
  walker
  ensure_timestamp_appended
  set_listen_address
  service_port
  change_sec_to_word
  find_video_files
  fix_top_level_help
  looks_like_url_with_scheme
  check_df
  download_rate
  download_speed
  is_host_local
  format_tx_error
  regex_match
  config_autocommit_enabled
);

our @EXPORT_OK = qw(
  prjdir
  sharedir
  archivedir
  resultdir
  assetdir
  imagesdir
  base_host
  determine_web_ui_web_socket_url
  get_ws_status_only_url
  random_string
  random_hex
  regex_match
  usleep_backoff
);

# override OPENQA_BASEDIR for tests
if ($0 =~ /\.t$/) {
    # This should result in the 't' directory, even if $0 is in a subdirectory
    my ($tdirname) = $0 =~ m{((.*/t/|^t/)).+$};
    # remove ./
    $tdirname = File::Spec->canonpath($tdirname);
    $ENV{OPENQA_BASEDIR} ||= "$tdirname/data";
}

sub prjdir () { ($ENV{OPENQA_BASEDIR} || '/var/lib') . '/openqa' }

sub sharedir () { $ENV{OPENQA_SHAREDIR} || (prjdir() . '/share') }

sub archivedir () { $ENV{OPENQA_ARCHIVEDIR} || (prjdir() . '/archive') }

sub resultdir ($archived = 0) { ($archived ? archivedir() : prjdir()) . '/testresults' }

sub assetdir () { sharedir() . '/factory' }

sub imagesdir () { prjdir() . '/images' }

# the desired new folder structure is
# $testcasedir/<testrepository>
# with "main.pm" and needles being in a productdir under <testrepository>
# defined by $distri forming the full path of
#  $testcasedir/<testrepository>/products/$distri
# with a fallback to searching for the main.pm in the <testrepository> top
# folder. <testrepository> is formed by $distri and $version with path lookup
# but could later on also be defined with a variable if necessary.
# To be backwards compatible we need to search for all combinations of "old/new
# testrepository name" and "old/new folder structure" within the
# testrepository.
sub productdir ($distri = undef, $version = undef, $rootfortests = undef) {
    my $dir = testcasedir($distri, $version, $rootfortests);
    return "$dir/products/$distri" if $distri && -e "$dir/products/$distri";
    return $dir;
}

sub testcasedir ($distri = undef, $version = undef, $rootfortests = undef) {
    my $prjdir = prjdir();
    my $defaultroot = catdir($prjdir, 'share', 'tests');
    for my $dir ($defaultroot, catdir($prjdir, 'tests')) {
        $rootfortests ||= $dir if -d $dir;
    }
    $rootfortests ||= $defaultroot;
    $distri //= '';
    # TODO actually "distri" is misused here. It should rather be something
    # like the name of the repository with all tests
    my $dir = catdir($rootfortests, $distri);
    $dir .= "-$version" if $version && -e "$dir-$version";
    return $dir;
}

=head2 gitrepodir

  gitrepodir(distri => DISTRI, version => VERSION)

I<gitrepodir> reads the F<.git/config> of the projects and returns
the http(s) address of the remote repository B<origin>.
The parameters are used to get the correct project directories either for
needles or tests.

If the I<.git> directory not found it returns an empty string.

=cut

sub gitrepodir (@args) {
    my %args = (distri => '', version => '', @args);
    my $path = $args{needles} ? needledir($args{distri}, $args{version}) : testcasedir($args{distri}, $args{version});
    my $filename = (-e path($path, '.git')) ? path($path, '.git', 'config') : '';
    my $config = Config::Tiny->read($filename, 'utf8');
    return '' unless defined $config;
    if ($config->{'remote "origin"'}{url} =~ /^http(s?)/) {
        my $repo_url = $config->{'remote "origin"'}{url};
        $repo_url =~ s{\.git$}{/commit/};
        return $repo_url;
    }
    my @url_tokenized = split(':', $config->{'remote "origin"'}{url});
    $url_tokenized[1] =~ s{\.git$}{/commit/};
    my @githost = split('@', $url_tokenized[0]);
    return "https://$githost[1]/$url_tokenized[1]";
}

sub is_in_tests ($file) {
    $file = File::Spec->rel2abs($file);
    # at least tests use a relative $prjdir, so it needs to be converted to absolute path as well
    my $abs_projdir = File::Spec->rel2abs(prjdir());
    return index($file, catdir($abs_projdir, 'share', 'tests')) == 0
      || index($file, catdir($abs_projdir, 'tests')) == 0;
}

sub needledir (@args) { productdir(@args) . '/needles' }

# Adds a timestamp to a string (eg. needle name) or replace the already present timestamp
sub ensure_timestamp_appended ($str) {
    my $today = strftime('%Y%m%d', gmtime(time));
    if ($str =~ /(.*)-\d{8}$/) {
        return "$1-$today";
    }
    return "$str-$today";
}

sub save_base64_png ($dir, $newfile, $png) {
    return unless $newfile && defined($png);
    # sanitize
    $newfile =~ s,\.png,,;
    $newfile =~ tr/a-zA-Z0-9-/_/cs;
    open(my $fh, '>', $dir . "/$newfile.png") || die "can't open $dir/$newfile.png: $!";
    use MIME::Base64 'decode_base64';
    $fh->print(decode_base64($png));
    close($fh);
    return $newfile;
}

sub image_md5_filename ($md5, $onlysuffix = undef) {
    my $prefix1 = substr($md5, 0, 3);
    $md5 = substr($md5, 3);
    my $prefix2 = substr($md5, 0, 3);
    $md5 = substr($md5, 3);

    if ($onlysuffix) {
        # stored this way in the database
        return catfile($prefix1, $prefix2, "$md5.png");
    }

    my $imagesdir = imagesdir();
    return (
        catfile($imagesdir, $prefix1, $prefix2, "$md5.png"),
        catfile($imagesdir, $prefix1, $prefix2, '.thumbs', "$md5.png"));
}

# returns the url to the web socket proxy started via openqa-livehandler
sub determine_web_ui_web_socket_url ($job_id) { "liveviewhandler/tests/$job_id/developer/ws-proxy" }

# returns the url for the status route over websocket proxy via openqa-livehandler
sub get_ws_status_only_url ($job_id) { "liveviewhandler/tests/$job_id/developer/ws-proxy/status" }

sub run_cmd_with_log ($cmd) { run_cmd_with_log_return_error($cmd)->{status} }

sub run_cmd_with_log_return_error ($cmd, %args) {
    my $stdout_level = $args{stdout} // 'debug';
    my $stderr_level = $args{stderr} // 'debug';
    my $output_file = $args{output_file};
    log_info('Running cmd: ' . join(' ', @$cmd));
    try {
        my ($stdin, $stdout, $stderr) = ('') x 3;
        my @out_args = defined $output_file ? ('>', $output_file, '2>', \$stderr) : (\$stdout, \$stderr);
        my $ipc_run_succeeded = IPC::Run::run($cmd, \$stdin, @out_args);
        my $error_code = $?;
        my $return_code = ($error_code & 127) ? (undef) : ($error_code >> 8);
        my $message
          = defined $return_code
          ? ("cmd returned $return_code")
          : sprintf('cmd died with signal %d', $error_code & 127);
        my $expected_return_codes = $args{expected_return_codes};
        chomp $stderr;
        if (
            $expected_return_codes
            ? (defined($return_code) && $expected_return_codes->{$return_code})
            : $ipc_run_succeeded
          )
        {
            OpenQA::Log->can("log_$stdout_level")->($stdout);
            OpenQA::Log->can("log_$stderr_level")->($stderr);
            log_info $message;
        }
        else {
            log_warning($stdout . $stderr);
            log_error $message;
        }
        return {
            status => $ipc_run_succeeded,
            return_code => $return_code,
            stdout => $stdout,
            stderr => $stderr,
        };
    }
    catch ($e) {
        return {
            status => 0,
            return_code => undef,
            stderr => 'an internal error occurred',
            stdout => '',
        };
    }
}

# passing $value is optional but makes the result more accurate
# (it affects only UEFI_PFLASH_VARS currently).
sub asset_type_from_setting ($setting, $value = undef) {
    return 'iso' if $setting eq 'ISO' || $setting =~ /^ISO_\d+$/;
    return 'hdd' if $setting =~ /^HDD_\d+$/;
    # non-absolute-path value of UEFI_PFLASH_VARS treated as HDD asset
    return 'hdd' if $setting eq 'UEFI_PFLASH_VARS' && ($value // '') !~ m,^/,;
    return 'repo' if $setting =~ /^REPO_\d+$/;
    return 'other' if $setting =~ /^ASSET_\d+$/ || $setting eq 'KERNEL' || $setting eq 'INITRD';
    # empty string if this doesn't look like an asset type
    return '';
}

sub parse_assets_from_settings ($settings) {
    my $assets = {};

    for my $k (keys %$settings) {
        if (my $type = asset_type_from_setting($k, $settings->{$k})) {
            $assets->{$k} = {type => $type, name => $settings->{$k}};
        }
    }

    return $assets;
}

sub _relative_or_absolute ($path, $relative = 0) {
    return $path if $relative;
    return catfile(assetdir(), $path);
}

# find the actual disk location of a given asset. Supported arguments are
# mustexist => 1 - return undef if the asset is not present
# relative => 1 - return path below assetdir, otherwise absolute path
sub locate_asset ($type, $name, %args) {
    my $trans = catfile($type, $name);
    return _relative_or_absolute($trans, $args{relative}) if -e _relative_or_absolute($trans);

    my $fixed = catfile($type, 'fixed', $name);
    return _relative_or_absolute($fixed, $args{relative}) if -e _relative_or_absolute($fixed);

    return $args{mustexist} ? undef : _relative_or_absolute($trans, $args{relative});
}

sub find_labels ($text) {
    my @labels;
    push @labels, $+{match} while ($text // '') =~ /${\LABEL_REGEX}/g;
    return \@labels;
}

sub find_flags ($text) {
    my @flags;
    push @flags, $+{match} while ($text // '') =~ /${\FLAG_REGEX}/g;
    return \@flags;
}

sub find_bugref ($text) { ($text // '') =~ BUGREF_REGEX ? $+{match} : undef }

sub find_bugrefs ($text) {
    my @bugrefs;
    push @bugrefs, $+{match} while ($text // '') =~ /${\BUGREF_REGEX}/g;
    return \@bugrefs;
}

sub bugurl ($bugref) {
    # in github '/pull/' and '/issues/' are interchangeable, e.g.
    # calling https://github.com/os-autoinst/openQA/issues/966 will yield the
    # same page as https://github.com/os-autoinst/openQA/pull/966 and vice
    # versa for both an issue as well as pull request
    # for pagure.io it has to be "issue", not "issues"
    $bugref =~ BUGREF_REGEX;
    my $issuetext = $+{marker} eq 'pio' ? 'issue' : 'issues';
    return $BUGREFS{$+{marker}} . ($+{repo} ? "$+{repo}/$issuetext/" : '') . $+{id};
}

sub bugref_to_href ($text) {
    my $regex = BUGREF_REGEX;
    $text =~ s{$regex}{<a href="@{[bugurl($+{match})]}">$+{match}</a>}gi;
    return $text;
}

sub href_to_bugref ($text) {
    my $regex = $MARKER_URLS =~ s/\?/\\\?/gr;
    # <repo> is optional, e.g. for github. For github issues and pull are
    # interchangeable, see comment in 'bugurl', too
    # gitlab URLs have an odd /-/ after the repo name, e.g.
    # https://gitlab.gnome.org/GNOME/gnome-shell/-/issues/5244
    $regex = qr{(?<!["\(\[])(?<url_root>$regex)((?<repo>.*?)/(-/)?(issues?|pull)/)?(?<id>([A-Z]+-)?\d+)(?![\w])};
    $text =~ s{$regex}{@{[$BUGURLS{$+{url_root}} . ($+{repo} ? '#' . $+{repo} : '')]}#$+{id}}gi;
    return $text;
}

sub url_to_href ($text) {
    $text =~ s!($RE{URI}$FRAG_REGEX)!<a href="$1">$1</a>!gx;
    return $text;
}

sub render_escaped_refs ($text) { bugref_to_href(url_to_href(xml_escape($text))) }

sub find_bug_number ($text) { $text =~ /\S+\-((?:$MARKER_REFS)\d+)\-\S+/ ? $1 : undef }

sub check_download_url ($url, $passlist) {
    # Passed a URL and the download_domains passlist from openqa.ini.
    # Checks if the host of the URL is in the passlist. Returns an
    # array: (1, host) if there is a passlist and the host is not in
    # it, (2, host) if there is no passlist, and () if we pass. This
    # is used by check_download_passlist below (and so indirectly by
    # the Iso controller) and directly by the download_asset() Gru
    # task subroutine.
    my $host = Mojo::URL->new($url)->host;
    return (2, $host) unless defined $passlist;
    my @okdomains = split(/ /, $passlist);
    my $ok = 0;
    for my $okdomain (@okdomains) {
        my $quoted = qr/$okdomain/;
        return () if $host =~ /${quoted}$/;
    }
    return (1, $host);
}

sub check_download_passlist ($params, $passlist) {
    # Passed the params hash ref for a job and the download_domains
    # passlist read from openqa.ini. Checks that all params ending
    # in _URL (i.e. requesting asset download) specify URLs that are
    # passlisted (except those starting with __ as they are not
    # actually download). It's provided here so that we can run the
    # check twice, once to return immediately and conveniently from
    # the Iso controller, once again directly in the Gru asset download
    # sub just in case someone somehow manages to bypass the API and
    # create a gru task directly. On failure, returns an array of 4
    # items: the first is 1 if there was a passlist at all or 2 if
    # there was not, the second is the name of the param for which the
    # check failed, the third is the URL, and the fourth is the host.
    # On success, returns an empty array.
    my @okdomains;
    @okdomains = split(/ /, $passlist) if defined $passlist;
    for my $param (keys %$params) {
        next unless ($param =~ /^(?!__).*_URL$/);
        next unless asset_type_from_setting((get_url_short($param))[0]);
        my $url = $$params{$param};
        my @check = check_download_url($url, $passlist);
        next unless (@check);
        # if we get here, we got a failure
        return ($check[0], $param, $url, $check[1]);
    }
    # empty list signals caller that check passed
    return ();
}

sub get_url_short ($arg) {
    # Given a setting name, if it ends with _URL or _DECOMPRESS_URL
    # return the name with that string stripped, and a flag indicating
    # whether decompression will be needed. If it doesn't, returns
    # empty string and 0.
    return ('', 0) unless $arg =~ s/_URL$//;
    return $arg =~ s/_DECOMPRESS$// ? ($arg, 1) : ($arg, 0);
}

sub create_downloads_list ($job_settings) {
    my %downloads;
    for my $arg (keys %$job_settings) {
        my $url = $job_settings->{$arg};
        my ($short, $do_extract) = get_url_short($arg);
        next unless ($short);
        my $filename = $job_settings->{$short};
        unless ($filename) {
            log_debug("No target filename set for $url. Ignoring $arg");
            next;
        }
        # We're only going to allow downloading of asset types. We also
        # need this to determine the download location later
        my $assettype = asset_type_from_setting($short, $job_settings->{$short});
        unless ($assettype) {
            log_debug("_URL downloading only allowed for asset types! $short is not an asset type");
            next;
        }
        # Find where we should download the file to
        my $fullpath = locate_asset($assettype, $filename, mustexist => 0);

        unless (-s $fullpath) {
            # if the file doesn't exist, add the url/target path and extraction
            # flag as a key/value pair to the %downloads hash
            $downloads{$url} = [$fullpath, $do_extract];
        }
    }
    return \%downloads;
}

sub create_git_clone_list ($job_settings, $clones = {}) {
    return $clones unless my $distri = $job_settings->{DISTRI};
    my $config = OpenQA::App->singleton->config->{'scm git'};
    if ($config->{git_auto_update} eq 'yes') {
        # Potential existing git clones to update without having CASEDIR or NEEDLES_DIR
        not $job_settings->{CASEDIR} and $clones->{testcasedir($distri)} = undef;
        not $job_settings->{NEEDLES_DIR} and $clones->{needledir($distri)} = undef;
    }
    if ($config->{git_auto_clone} eq 'yes') {
        # Check CASEDIR and NEEDLES_DIR
        my $case_url = Mojo::URL->new($job_settings->{CASEDIR} // '');
        my $needles_url = Mojo::URL->new($job_settings->{NEEDLES_DIR} // '');
        if ($case_url->scheme) {
            $case_url->fragment($job_settings->{TEST_GIT_REFSPEC}) if ($job_settings->{TEST_GIT_REFSPEC});
            $clones->{testcasedir($distri)} = $case_url;
        }
        if ($needles_url->scheme) {
            $needles_url->fragment($job_settings->{NEEDLES_GIT_REFSPEC}) if ($job_settings->{NEEDLES_GIT_REFSPEC});
            $clones->{needledir($distri)} = $needles_url;
        }
    }
    return $clones;
}

# give it one digit
sub _round_a_bit ($size) { $size < 10 ? int($size * 10 + .5) / 10. : int($size + .5) }

sub human_readable_size ($size) {
    my $p = ($size < 0) ? '-' : '';
    $size = abs($size);
    return "$p$size Byte" if $size < 3000;
    $size /= 1024.;
    return $p . _round_a_bit($size) . ' KiB' if $size < 1024;
    $size /= 1024.;
    return $p . _round_a_bit($size) . ' MiB' if $size < 1024;
    $size /= 1024.;
    return $p . _round_a_bit($size) . ' GiB';
}

sub read_test_modules ($job) {
    return undef unless my $testresultdir = $job->result_dir;

    my $category;
    my $has_parser_text_results = 0;
    my (@modlist, @errors);

    for my $module ($job->modules_with_job_prefetched->all) {
        my $name = $module->name();
        # add link to $testresultdir/$name*.png via png CGI
        my @details;

        my $num = 1;
        my $has_module_parser_text_result = 0;

        my $module_results = $module->results(errors => \@errors);
        for my $step (@{$module_results->{details}}) {
            my $text = $step->{text};
            my $source = $step->{_source};

            $step->{num} = $num++;
            $step->{display_title} = ($text ? $step->{title} : $step->{name}) // '';
            $step->{is_parser_text_result} = 0;
            if ($source && $source eq 'parser' && $text && $step->{text_data}) {
                $step->{is_parser_text_result} = 1;
                $has_module_parser_text_result = 1;
            }

            $step->{resborder} = 'resborder_' . (($step->{result} && !(ref $step->{result})) ? $step->{result} : 'unk');

            push(@details, $step);
        }

        $has_parser_text_results = 1 if ($has_module_parser_text_result);

        push(
            @modlist,
            {
                name => $module->name,
                result => $module->result,
                details => \@details,
                milestone => $module->milestone,
                important => $module->important,
                fatal => $module->fatal,
                always_rollback => $module->always_rollback,
                has_parser_text_result => $has_module_parser_text_result,
                execution_time => change_sec_to_word($module_results->{execution_time}),
            });

        if (!$category || $category ne $module->category) {
            $category = $module->category;
            $modlist[-1]->{category} = $category;
        }

    }

    return {modules => \@modlist, errors => \@errors, has_parser_text_results => $has_parser_text_results};
}

# parse comments of the specified (parent) group and store all mentioned builds in $res (hashref)
sub parse_tags_from_comments ($group, $res) {
    return unless my $comments = $group->comments;

    while (my $comment = $comments->next) {
        my @tag = $comment->tag;
        next unless my $build = $tag[0];

        my $version = $tag[3];
        my $tag_id = $version ? "$version-$build" : $build;
        if ($tag[1] eq '-important') {
            delete $res->{$tag_id};
            next;
        }

        # ignore tags on non-existing builds
        $res->{$tag_id} = {build => $build, type => $tag[1], description => $tag[2], version => $version};
    }
}

sub detect_current_version ($path) {
    # Get application version
    my $current_version = undef;
    my $changelog_file = path($path, 'public', 'Changelog');
    my $head_file = path($path, '.git', 'refs', 'heads', 'master');
    my $refs_file = path($path, '.git', 'packed-refs');

    if (-e $changelog_file) {
        my $changelog = $changelog_file->slurp;
        if ($changelog && $changelog =~ /Update to version (\d+\.\d+\.(\b[0-9a-f]{5,40}\b))\:/mi) {
            $current_version = $1;
        }
    }
    elsif (-e $head_file && -e $refs_file) {
        my $master_head = $head_file->slurp;
        my $packed_refs = $refs_file->slurp;

        # Extrapolate latest tagged version and combine it
        # with latest commit which heads is pointed to.
        # This method have its limits while checking out different branches
        # but emulates git-describe output without executing commands.
        if ($master_head && $packed_refs) {
            my $latest_ref = (grep(/tags/, split(/\s/, $packed_refs)))[-1];
            my $partial_hash = substr($master_head, 0, 8);
            if ($latest_ref && $partial_hash) {
                my $tag = (split(/\//, $latest_ref))[-1];
                $current_version = $tag ? 'git-' . $tag . '-' . $partial_hash : undef;
            }
        }
    }
    return $current_version;
}

# Resolves a path to class
# path is expected to be in the form of the keys of %INC. e.g. : foo/bar/baz.pm
sub path_to_class { substr join('::', split(/\//, shift)), 0, -3 }

# Returns all modules that are loaded into memory
sub loaded_modules {
    map { path_to_class($_); } sort keys %INC;
}

# Fallback to loaded_modules if no arguments are given.
# Accepts namespaces as arguments. If supplied, it will filter by them
sub loaded_plugins (@ns) {
    my $ns = join('|', map { quotemeta } @ns);
    return @ns ? grep { /^$ns/ } loaded_modules() : loaded_modules();
}

# Walks a hash keeping keys as a stack
sub hashwalker ($hash, $callback, $keys = undef) {
    $keys = [] if !$keys;
    foreach my $key (sort keys %$hash) {
        my $value = $hash->{$key};
        push @$keys, $key;
        if (ref($value) eq 'HASH') {
            hashwalker($value, $callback, $keys);
        }
        else {
            $callback->($key, $value, $keys);
        }
        pop @$keys;
    }
}

# Walks whatever
sub walker ($hash, $callback, $keys = []) {
    if (reftype $hash eq 'HASH') {
        foreach my $key (sort keys %$hash) {
            push @$keys, [reftype($hash), $key];
            my $k_ref = reftype $hash->{$key};
            if ($k_ref && $k_ref eq 'HASH') {
                walker($hash->{$key}, $callback, $keys);
                $callback->($key, $hash->{$key}, $keys, $hash);
            }
            elsif ($k_ref && $k_ref eq 'ARRAY') {
                walker($hash->{$key}, $callback, $keys);
                $callback->($key, $hash->{$key}, $keys, $hash);
            }
            else {
                $callback->($key, $hash->{$key}, $keys, $hash);
            }
            pop @$keys;
        }
    }
    elsif (reftype $hash eq 'ARRAY') {
        my $i = 0;
        for my $elem (@{$hash}) {
            push @$keys, [reftype($hash), $i];
            my $el_ref = reftype $elem;
            if ($el_ref && $el_ref eq 'ARRAY') {
                walker($elem, $callback, $keys);
                $callback->($i, $elem, $keys, $hash);
            }
            elsif ($el_ref && $el_ref eq 'HASH') {
                walker($elem, $callback, $keys);
                $callback->($i, $elem, $keys, $hash);
            }

            $i++;
            pop @$keys;
        }
    }
}

sub set_listen_address ($port) {
    return if $ENV{MOJO_LISTEN};
    my @listen_addresses = ("http://127.0.0.1:$port?reuse=1");

    # Check for IPv6
    push @listen_addresses, "http://[::1]:$port?reuse=1" if IO::Socket::IP->new(Listen => 5, LocalAddr => '::1');

    $ENV{MOJO_LISTEN} = join ',', @listen_addresses;
}

sub service_port ($service) {
    my $base = $ENV{OPENQA_BASE_PORT} ||= 9526;
    my $offsets = {
        webui => 0,
        websocket => 1,
        livehandler => 2,
        scheduler => 3,
        cache_service => 4
    };
    croak "Unknown service: $service" unless exists $offsets->{$service};
    return $base + $offsets->{$service};
}

sub random_string ($length = RANDOM_STRING_DEFAULT_LENGTH, $chars = ['a' .. 'z', 'A' .. 'Z', '0' .. '9', '_']) {
    return join('', map { $chars->[rand @$chars] } 1 .. $length);
}

sub random_hex ($length = RANDOM_STRING_DEFAULT_LENGTH) {
    my $toread = $length / 2 + $length % 2;
    # uncoverable branch true
    open(my $fd, '<:raw:bytes', '/dev/urandom') || croak "can't open /dev/urandom: $!";
    # uncoverable branch true
    read($fd, my $bytes, $toread) || croak "can't read random byte: $!";
    close $fd;
    return uc substr(unpack('H*', $bytes), 0, $length);
}

sub any_array_item_contained_by_hash ($array, $hash) {
    for my $array_item (@$array) {
        return 1 if ($hash->{$array_item});
    }
    return 0;
}

sub base_host { Mojo::URL->new($_[0])->host || $_[0] }

sub change_sec_to_word ($second = undef) {
    return undef unless $second;
    return undef if ($second !~ /^[[:digit:]]+$/);
    my %time_numbers = (
        d => ONE_DAY,
        h => ONE_HOUR,
        m => ONE_MINUTE,
        s => 1
    );
    my $time_word = '';
    for my $key (qw(d h m s)) {
        $time_word .= int($second / $time_numbers{$key}) . $key . ' '
          if (int($second / $time_numbers{$key}));
        $second = int($second % $time_numbers{$key});
    }
    $time_word =~ s/\s$//g;
    return $time_word;
}

sub find_video_files { path(shift)->list_tree->grep(VIDEO_FILE_NAME_REGEX) }

# workaround https://github.com/mojolicious/mojo/issues/1629
sub fix_top_level_help { @ARGV = () if ($ARGV[0] // '') =~ qr/^(-h|(--)?help)$/ }

sub looks_like_url_with_scheme { return !!Mojo::URL->new(shift)->scheme }

sub check_df ($dir) {
    my $df = Filesys::Df::df($dir, 1) // {};
    my $available_bytes = $df->{bavail};
    my $total_bytes = $df->{blocks};
    die "Unable to determine disk usage of '$dir'"
      unless looks_like_number($available_bytes)
      && looks_like_number($total_bytes)
      && $total_bytes > 0
      && $available_bytes >= 0
      && $available_bytes <= $total_bytes;
    return ($available_bytes, $total_bytes);
}

sub download_rate ($start, $end, $bytes) {
    my $interval = tv_interval($start, $end);
    return undef if $interval == 0;
    return sprintf('%.2f', $bytes / $interval);
}

sub download_speed ($start, $end, $bytes) {
    my $rate = download_rate($start, $end, $bytes);
    return '??/s' unless defined $rate;
    my $human = human_readable_size($rate);
    return "$human/s";
}

sub is_host_local ($host) { $host eq 'localhost' || $host eq '127.0.0.1' || $host eq '[::1]' }

sub format_tx_error ($err) {
    $err->{code} ? "$err->{code} response: $err->{message}" : "Connection error: $err->{message}";
}

# compiles the specified $regex_string and matches it against $string
# note: Regexp warnings are treated as failures and will not show up in the server logs. This is useful
#       for using user-provided regexes that may be invalid.
sub regex_match ($regex_string, $string) {
    use warnings FATAL => 'regexp';
    try { return $string =~ /$regex_string/ }
    catch ($e) { die "invalid regex: $e" }
}

# Returns a microsecond value suitable for use with "usleep". For the first iteration it returns the minimum value plus
# random 0-1 second padding, and starting with the second iteration the delay increases by one second plus 0-1 second
# padding, up to the maximum.
sub usleep_backoff ($iteration, $min_seconds, $max_seconds, $padding = int(rand(ONE_SECOND_IN_MICROSECONDS))) {

    # To allow for backoff to be disabled easily
    return 0 if $min_seconds == 0;

    my $delay = (($min_seconds + $iteration - 1) * ONE_SECOND_IN_MICROSECONDS) + $padding;
    return min($max_seconds * ONE_SECOND_IN_MICROSECONDS, $delay);
}

# whether we consider git auto-commit enabled or not, handling
# compatibility with the old 'scm = git' setting
sub config_autocommit_enabled ($config) {
    return 0 if $config->{'scm git'}{git_auto_commit} eq 'no';
    return ($config->{global}->{scm} || '') eq 'git' || $config->{'scm git'}{git_auto_commit} eq 'yes';
}

1;
