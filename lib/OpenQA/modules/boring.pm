#!/usr/bin/env perl
use strict;
use warnings;
package boring;

sub expect($$$){
    my($results,$t,$v)=@_;
    #	print "$t\n";
    my $r=$results->{$t};
    return if(!$r);
    if($r eq $v) {
        delete $results->{$t};
    }
    else {
        $results->{$t}.="surprising";
    }
}
sub ignore($$){
    my($results,$t)=@_;
    delete $results->{$t};
}

sub is_boring($$){
    my($name,$results)=@_;
    foreach my $t (keys %$results) { $results->{$t}=~s/ .*//; } # strip extras
    #return 1 unless $results->{overall} eq "OK";#temp broken
    #return 1 if($name=~m/i586-.*-kerneldevel/); # bnc#667542
    ignore($results,"firefox");
    ignore($results,"application_browser");
    if($name=~m/-LiveCD/) {
        #expect($results, "yast2_lan", "unknown");
    }
    if($name=~m/-usbboot/) {
        #expect($results, "overall", "fail");
        #expect($results, "standstill", "fail");
        #return 1 if(!$results->{overall} && !$results->{standstill});
    }
    if($name=~m/-i[56]86-/) {
        #return 1; # https://bugzilla.novell.com/show_bug.cgi?id=660464
    }
    if($name=~m/-11.3dup/) {
        #return 1 if($results->{booted} eq "unknown");
    }
    #delete $results->{sshxterm}; # sigs need updating - waiting for dheidler
    delete $results->{firefox}; # sigs need update for 4.0 final
    delete $results->{ooffice}; # broken on factory 20110401
    delete $results->{banshee}; # sigs need update
    delete $results->{NET_inst_mirror}; # randomly fails from pingus
    delete $results->{reboot_wait_for_grub}; # randomly fails from pingus
    delete $results->{kontact}; # randomly fails from bnc#668138
    #if($results->{ooffice}) { expect($results, "ooffice", "unknown"); }
    #if($results->{amarok}) { expect($results, "amarok", "unknown"); }
    if($name=~m/-lxde/) {
        #		expect($results, "sshxterm", "unknown");
    }
    if($name=~m/-gnome/) {
        #delete $results->{xterm}; # randomly fails from policykit auth popups
    }
    if($name=~m/-[DN][VE][DT]-.*-RAID10/) {
        # https://bugzilla.novell.com/show_bug.cgi?id=656536
        #expect($results, "kde_reboot_plasmatheme", "unknown");
        #expect($results, "standstill", "fail");
    }
    if($name=~m/openSUSE-[DN][VE][DT]-/) {
        # https://bugzilla.novell.com/show_bug.cgi?id=652562
        #expect($results, "ooffice", "unknown"); # workarounded
    }
    expect($results, "glxgears", "fail");


    my $allok=1;
    my $nonok=0;
    my $ok=0;
    foreach my $t (keys %$results) {
        my $r=$results->{$t};
        if($r eq "not-autochecked") {next}
        if($r ne "OK") {$allok=0; $nonok++}
        else {$ok++}
    }
    #print "$name ok:$ok other:$nonok\n";
    return 1 if $allok;
    return 0;
}

sub test(){
    is_boring("openSUSE-NET-i586-Build1016-lxde", {}) or die;
    is_boring("openSUSE-NET-x86_64-Build1016", {ooffice=>"unknown"}) or die;
    is_boring("openSUSE-NET-x86_64-Build1016-RAID10", {ooffice=>"unknown", "kde_reboot_plasmatheme"=>"unknown"}) or die;
    is_boring("openSUSE-NET-x86_64-Build1016", {ooffice=>"unknown", booted=>"unknown", overall=>"fail"}) and die;
    is_boring("openSUSE-KDE-LiveCD-x86_64-Build1016", {booted=>"OK", overall=>"OK"}) or die;
    is_boring("openSUSE-KDE-LiveCD-x86_64-Build1016", {booted=>"OK", firefox=>"unknown", overall=>"OK"}) and die;
    print "OK\n";
}

test() if($ENV{TESTBORING});

1;
# vim: set sw=4 et:
