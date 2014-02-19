BEGIN { unshift @INC, 'lib', 'lib/OpenQA/modules'; }

use Mojo::Base -strict;

use Test::More;
use Test::Mojo;

my $t = Test::Mojo->new('OpenQA');

my $cfg = $t->app->config;

is(length($cfg->{openid_secret}), 16, "config has openid_secret");
delete $cfg->{openid_secret};

is_deeply($cfg,{
		needles_git_do_push  => "no",
		needles_git_worktree => "/var/lib/os-autoinst/needles",
		needles_scm          => "git",
	}, 'default config');

$ENV{OPENQA_CONFIG} = 't/testcfg.ini';
open(my $fd, '>', $ENV{OPENQA_CONFIG});
print $fd "allowed_hosts=foo bar\n";
print $fd "suse_mirror=http://blah/\n";
close $fd;

$t = Test::Mojo->new('OpenQA');
ok($t->app->config->{'allowed_hosts'} eq 'foo bar', 'allowed hosts');
ok($t->app->config->{'suse_mirror'} eq 'http://blah/', 'suse mirror');

unlink($ENV{OPENQA_CONFIG});

done_testing();
