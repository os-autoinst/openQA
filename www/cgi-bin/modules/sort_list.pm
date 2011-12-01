# produce a sortable HTML table from a @list
#
# Copyright 2007 Bernhard M. Wiedemann
# Licensed for use, modification, distribution etc
# under the terms of GNU General Public License v2 or later

package sort_list;
use strict;
require 5.002;

require Exporter;
our ($VERSION, @ISA, @EXPORT, @EXPORT_OK, %EXPORT_TAGS);
$VERSION = sprintf "%d.%03d", q$Revision: 1.12 $ =~ /(\d+)/g;
@ISA = qw(Exporter);
@EXPORT = qw(
&sort_num &sort_string &sort_istring &sort_list &sort_param_to_keys
);

# this file defines functions to output a sorted table.

sub sort_num($$) {if(!defined($_[0]) || !defined($_[1])) {return 0} my @a=@_; $a[0]=~s/\D//g;$a[1]=~s/\D//g; (($a[0]||0)<=>($a[1]||0))}
sub sort_string($$) {$_[0] cmp $_[1]}
sub sort_istring($$) {lc($_[0]) cmp lc($_[1])}

sub sort_list($$$) {
	my($sortfunc, $sortkeys, $data)=@_;
	return sort(
	{
		foreach(@$sortkeys) {
			my $sk=$_; # actual sort key
			my $desc = $sk=~s/^-//;
			my $sf=$$sortfunc{$sk};
			if(!$sf) {$sf=\&sort_string}
			my $cmp=&$sf($$a{$sk}, $$b{$sk});
			if($cmp) {
				return -$cmp if $desc;
				return $cmp;
			}
		}
		return 0;
	}
	@$data);
}

# this takes a CGI argument and converts it into a sortkeys arrayref 
# suitable for use with sort_table function
sub sort_param_to_keys($) { my($param)=@_;
   $param=~s/[^-+_0-9A-Za-z.]//g; # sanitize user input;
   return [split(/\./,$param)];
}

1;
