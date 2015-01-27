package OpenQA::Utils;
use strict;
require 5.002;

use Carp;

require Exporter;
our ($VERSION, @ISA, @EXPORT, @EXPORT_OK, %EXPORT_TAGS);
$VERSION = sprintf "%d.%03d", q$Revision: 1.12 $ =~ /(\d+)/g;
@ISA = qw(Exporter);
@EXPORT = qw(
  $prj
  $basedir
  $resultdir
  $app_title
  $app_subtitle
  @runner
  &running_log
  &sortkeys
  &first_run
  &data_name
  &back_log
  &get_running_modinfo
  &needle_info
  &needledir
  &testcasedir
  &test_result
  &test_result_module
  &test_resultfile_list
  &testresultdir
  &test_uploadlog_list
  $localstatedir
  &get_failed_needles
  &sanitize_testname
  &file_content
);

@EXPORT_OK = qw/connect_db/;

if ($0 =~ /\.t$/) {
    # This should result in the 't' directory, even if $0 is in a subdirectory
    my ($tdirname) = $0 =~ qr/((.*\/t\/|^t\/)).+$/;
    $ENV{OPENQA_BASEDIR} ||= $tdirname.'data';
}

#use lib "/usr/share/openqa/cgi-bin/modules";
use File::Basename;
use Fcntl;
use JSON "decode_json";
our $basedir=$ENV{'OPENQA_BASEDIR'}||"/var/lib";
our $prj="openqa";
our $resultdir="$basedir/$prj/testresults";
our $assetdir="$basedir/$prj/factory";
our $isodir="$assetdir/iso";
our $cachedir="$basedir/$prj/cache";
our $hostname=$ENV{'SERVER_NAME'};
our $app_title = 'openQA test instance';
our $app_subtitle = 'openSUSE automated testing';
our $testcasedir = "$basedir/openqa/share/tests";

our @runner = <$basedir/$prj/pool/[0-9]>;
push(@runner, "$basedir/$prj/pool/manual");

sub test_result($) {
    my $testname = shift;
    my $testresdir = testresultdir($testname);
    local $/;
    #carp "reading json from $testresdir/results.json";
    open(JF, "<", "$testresdir/results.json") || return;
    return unless fcntl(JF, F_SETLKW, pack('ssqql', F_RDLCK, 0, 0, 0, $$));
    my $result_hash;
    eval {$result_hash = decode_json(<JF>);};
    warn "failed to parse $testresdir/results.json: $@" if $@;
    close(JF);
    return $result_hash;
}

sub test_result_module($$) {
    # get a certain testmodule subtree
    my $modules_array = shift;
    my $query_module = shift;
    for my $module (@{$modules_array}) {
        if($module->{'name'} eq $query_module) {
            return $module;
        }
    }
}

sub running_log($) {
    my ($name) = @_;
    return join('/', $basedir, $prj, 'testresults', $name, '/');
}

sub testcasedir($$) {
    my $distri = shift;
    my $version = shift;

    my $dir = "$testcasedir/$distri";
    $dir .= "-$version" if $version && -e "$dir-$version";

    return $dir;
}

sub back_log($) {
    my ($name) = @_;
    my $backlogdir = "*";
    my @backlogs = <$basedir/$prj/backlog/$backlogdir/name>;
    foreach my $filepath (@backlogs) {
        my $path = $filepath;
        $path=~s/\/name$//;
        open(my $fd, '<', $filepath) || next;
        my $rnam = <$fd>;
        chomp($rnam);
        close($fd);
        if ($name eq $rnam) {
            return $path."/";
        }
    }
    return "";
}

sub get_running_modinfo($) {
    my $results = shift;
    return {} unless $results;
    my $currentstep = $results->{'running'}||'';
    my $modlist = [];
    my $donecount = 0;
    my $count = @{$results->{'testmodules'}||[]};
    my $modstate = 'done';
    my $category;
    for my $module (@{$results->{'testmodules'}}) {
        my $name = $module->{'name'};
        my $result = $module->{'result'};
        if (!$category || $category ne $module->{'category'}) {
            $category = $module->{'category'};
            push(@$modlist, {'category' => $category, 'modules' => []});
        }
        if ($name eq $currentstep) {
            $modstate = 'current';
        }
        elsif ($modstate eq 'current') {
            $modstate = 'todo';
        }
        elsif ($modstate eq 'done') {
            $donecount++;
        }
        my $moditem = {'name' => $name, 'state' => $modstate, 'result' => $result};
        push(@{$modlist->[scalar(@$modlist)-1]->{'modules'}}, $moditem);
    }
    return {'modlist' => $modlist, 'modcount' => $count, 'moddone' => $donecount, 'running' => $results->{'running'}};
}


sub testresultdir($) {
    my $fn=shift;
    "$basedir/$prj/testresults/$fn";
}

sub test_resultfile_list($) {
    # get a list of existing resultfiles
    my $testname = shift;
    my $testresdir = testresultdir($testname);
    my @filelist = qw(video.ogv results.json vars.json backend.json serial0.txt autoinst-log.txt);
    my @filelist_existing;
    for my $f (@filelist) {
        if(-e "$testresdir/$f") {
            push(@filelist_existing, $f);
        }
    }
    return @filelist_existing;
}

sub test_uploadlog_list($) {
    # get a list of uploaded logs
    my $testname = shift;
    my $testresdir = testresultdir($testname);
    my @filelist;
    for my $f (<$testresdir/ulogs/*>) {
        $f=~s#.*/##;
        push(@filelist, $f);
    }
    return @filelist;
}

our $loop_first_run = 1;
sub first_run(;$) {
    if(shift) {
        $loop_first_run = 1;
        return;
    }
    if($loop_first_run) {
        $loop_first_run = 0;
        return 1;
    }
    else {
        return 0;
    }
}

sub sortkeys($$) {
    my $options = shift;
    my $sortname = shift;
    my $suffix = "";
    $suffix .= ".".$options->{'sort'}.(defined($options->{'hours'})?"&amp;hours=".$options->{'hours'}:"");
    $suffix .= (defined $options->{'match'})?"&amp;match=".$options->{'match'}:"";
    $suffix .= ($options->{'ib'})?"&amp;ib=on":"";
    my $dn_url = "?sort=-".$sortname.$suffix;
    my $up_url = "?sort=".$sortname.$suffix;
    return '<a rel="nofollow" href="'.$dn_url.'"><img src="/images/ico_arrow_dn.gif" style="border:0" alt="sort dn" /></a><a rel="nofollow" href="'.$up_url.'"><img src="/images/ico_arrow_up.gif" style="border:0" alt="sort up" /></a>';
}

sub data_name($) {
    $_[0]=~m/^.*\/(.*)\.\w\w\w(?:\.gz)?$/;
    return $1;
}

sub needledir($$) {
    return testcasedir($_[0], $_[1]).'/needles';
}

sub needle_info($$$) {
    my $name = shift;
    my $distri = shift;
    my $version = shift;
    local $/;

    my $needledir = needledir($distri, $version);

    my $fn = "$needledir/$name.json";
    unless (open(JF, '<', $fn )) {
        warn "$fn: $!";
        return undef;
    }

    my $needle;
    eval {$needle = decode_json(<JF>);};
    close(JF);

    if($@) {
        warn "failed to parse $needledir/$name.json: $@";
        return undef;
    }

    $needle->{'needledir'} = $needledir;
    $needle->{'image'} = "$needledir/$name.png";
    $needle->{'json'} = "$needledir/$name.json";
    $needle->{'name'} = $name;
    $needle->{'distri'} = $distri;
    $needle->{'version'} = $version;
    return $needle;
}

# actually it's also return failed modules
sub get_failed_needles($){
    my $testname = shift;
    return undef if !defined($testname);

    my $testresdir = testresultdir($testname);
    my $glob = "$testresdir/results.json";
    my $failures = {};
    my @failedneedles = ();
    my @failedmodules = ();
    for my $fn (glob $glob) {
        local $/; # enable localized slurp mode
        next unless -e $fn;
        open(my $fd, '<', $fn);
        next unless $fd;
        my $results = decode_json(<$fd>);
        close $fn;
        for my $module (@{$results->{testmodules}}) {
            next unless $module->{result} eq 'fail';
            push( @failedmodules, $module->{name} );
            for my $detail (@{$module->{details}}) {
                next unless $detail->{result} eq 'fail';
                next unless $detail->{needles};
                for my $needle (@{$detail->{needles}}) {
                    push( @failedneedles, $needle->{name} );
                }
                $failures->{$testname}->{failedneedles} = \@failedneedles;
            }
            $failures->{$testname}->{failedmodules} = \@failedmodules;
        }
    }
    return $failures;
}

sub sanitize_testname($){
    my $name = shift;
    $name =~ s/[^a-zA-Z0-9._+-]//g;
    return undef unless $name =~ /^[a-zA-Z]/;
    return $name;
}

sub connect_db{
    my $mode = shift || $ENV{OPENQA_DATABASE} || 'production';
    use OpenQA::Schema::Schema;
    CORE::state $schema;
    unless ($schema) {
        $schema = OpenQA::Schema->connect($mode) or die "can't connect to db: $!\n";
    }
    return $schema;
}

sub file_content($){
    my($fn)=@_;
    open(FCONTENT, "<", $fn) or return undef;
    local $/;
    my $result=<FCONTENT>;
    close(FCONTENT);
    return $result;
}

1;
# vim: set sw=4 et:
