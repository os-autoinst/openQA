# produce a sortable HTML table from a @list
#
# Copyright 2007 Bernhard M. Wiedemann
# Licensed for use, modification, distribution etc
# under the terms of GNU General Public License v2 or later

package sort_table;
use strict;
require 5.002;

require Exporter;
our ($VERSION, @ISA, @EXPORT, @EXPORT_OK, %EXPORT_TAGS);
$VERSION = sprintf "%d.%03d", q$Revision: 1.12 $ =~ /(\d+)/g;
@ISA = qw(Exporter);
@EXPORT = qw(
&display_string &display_round0 &display_round1 &display_round2 &display_time &sort_num &sort_string &sort_istring &sort_table &sort_param_to_keys
);
use awstandard;
use CGI qw":standard";

# this file defines functions to output a sorted table.

sub display_string($) { $_[0]; }
sub display_round0($) 
{ sprintf("%i",$_[0]) }
sub display_round1($)
{ sprintf("%.1f",$_[0]) }
sub display_round2($)
{ sprintf("%.2f",$_[0]) }

sub display_time{ my($n)=@_;
   return AWisodatetime2($n);
}

sub sort_num($$) {if(!defined($_[0]) || !defined($_[1])) {return 0} my @a=@_; $a[0]=~s/\D//g;$a[1]=~s/\D//g; (($a[0]||0)<=>($a[1]||0))}
sub sort_string($$) {$_[0] cmp $_[1]}
sub sort_istring($$) {lc($_[0]) cmp lc($_[1])}


sub sort_table($$$$$;$) { my($header, $displayfunc, $sortfunc, $sortkeys, $data, $rowfunc)=@_;
   my $headerstr="<table><tr>";
   {
      my $n=0;
      foreach(@$header) {
         next if not defined $$displayfunc[$n++];
         my $sortlinks="";
         for(0,1) {
            my $updown=$_?"up":"dn";
            my @newkeys=@$sortkeys;
            # TODO  test if new value is already present -> drop old
            unshift(@newkeys, $n*($_*2-1));
            my $sortval=join(".",@newkeys);
            my $oldparams=$ENV{QUERY_STRING};
            $oldparams=~s/sort=[-.0-9]*&?//;
            if($oldparams) {$oldparams="&$oldparams"}
            $sortlinks.=a({-href=>"?sort=$sortval$oldparams", -rel=>"nofollow"},img({-src=>"/images/ico_arrow_$updown.gif", -alt=>"sort $updown", -style=>"border:0"}));
         }
         if(! defined ($$sortfunc[$n-1])) {$sortlinks=""}
         $headerstr.=th($_.$sortlinks);
      }
   }
   $headerstr.="</tr>\n";
   my $outstr="";
   my $line=0;
   foreach my $row (sort 
         {
            foreach(@$sortkeys) {
               my $sk=abs($_)-1; # actual sort key
               my $sf=$$sortfunc[$sk];
               if(!$sf) {$sf=\&sort_string}
               my $cmp=&$sf($$a[$sk], $$b[$sk]);
               if($cmp) {
                  return $cmp if $_>0;
                  return -$cmp;
               }
            }
            return 0;
         }
         @$data) {
      $rowfunc && &$rowfunc($row);
      $outstr.="<tr class=\"".((++$line&1)?"odd":"even")."\">";
      my $n=0;
      foreach my $element (@$row) {
         my $df=$$displayfunc[$n++];
         next if not defined $df;
         $outstr.=td({-class=>"sort"},&$df($element));
      }
      $outstr.="</tr>\n";
   }
   return $headerstr.$outstr."</table>";
}

# this takes a CGI argument and converts it into a sortkeys arrayref 
# suitable for use with sort_table function
sub sort_param_to_keys($) { my($param)=@_;
   $param=~s/[^-+0-9.]//g; # sanitize user input;
   return [split(/\./,$param)];
}

1;
