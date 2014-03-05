# Copyright (C) 2014 SUSE Linux Products GmbH
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
# You should have received a copy of the GNU General Public License along
# with this program; if not, write to the Free Software Foundation, Inc.,
# 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.

package OpenQA;
use Mojo::Base 'Mojolicious';
use openqa 'connect_db';
use OpenQA::Helpers;
use Scheduler;
use Mojo::IOLoop;

use Config::IniFiles;

sub _read_config {
  my $self = shift;

  my %defaults = (
    global => {
      base_url => undef,
      allowed_hosts => undef,
      suse_mirror => undef,
      scm => 'git',
    },
    'scm git' => {
      do_push => 'no',
    },
    logging => {
      level => undef,
      file => undef,
    },
    openid => {
      provider => 'https://www.opensuse.org/openid/user/',
    }
  );

  # Mojo's built in config plugins suck. JSON for example does not
  # support comments
  my $cfg = Config::IniFiles->new(
      -file => $ENV{OPENQA_CONFIG} || $self->app->home.'/lib/openqa.ini') || undef;

  for my $section (sort keys %defaults) {
    for my $k (sort keys %{$defaults{$section}}) {
      my $v = $cfg && $cfg->val($section, $k) || $defaults{$section}->{$k};
      $self->app->config->{$section}->{$k} = $v if $v;
    }
  }
  $self->app->config->{_openid_secret} = $self->rndstr(16);
}

# check if have worker died
sub _workers_checker {
    my $self = shift;

    # Start recurring timer, check workers alive every 20 mins
    my $id = Mojo::IOLoop->recurring(1200 => sub {
	my @workers_time;

	my $workers_ref = Scheduler::list_workers();
	my $workers_count = scalar @$workers_ref;

	for my $workerid (1..$workers_count-1) {
	    my $worker = Scheduler::worker_get($workerid);
	    my $last_tupdated = $worker->{t_updated};
	    $workers_time[$workerid] = $last_tupdated;
	}

	for my $workerid (1..$workers_count-1) {
	    Mojo::IOLoop->timer(10 => sub {
		# check the t_updated again after 10 seconds
		my $worker = Scheduler::worker_get($workerid);
		my $cur_tupdated = $worker->{t_updated};

		# if t_updated didn't updated then assumed worker is died
		if($cur_tupdated eq $workers_time[$workerid]) {
		    print STDERR "found died worker $workerid\n";
		    my $job = Scheduler::job_get_by_workerid($workerid);
		    if($job) {
			Scheduler::job_cancel($job->{id});
			print STDERR "cancelled job $job->{id}\n";
		    } else {
			print STDERR "no jobs running on died worker $workerid\n";
		    }
		    # TODO: should rescheduled the cancelled job to avoid
		    # if job cancel failed
		}
	    });
	}
    });
}

has schema => sub {
    return connect_db();
};

# This method will run once at server start
sub startup {
  my $self = shift;

  # Set some application defaults
  $self->defaults( appname => 'openQA' );

  unshift @{$self->app->renderer->paths}, '/etc/openqa/templates';

  # read application secret from database
  my @secrets = $self->schema->resultset('Secrets')->all();
  if (!@secrets) {
    # create one if it doesn't exist
    $self->app->log->debug('creating secret');
    $self->schema->resultset('Secrets')->create({});
    @secrets = $self->schema->resultset('Secrets')->all();
  }
  die "couldn't create secrets\n" unless @secrets;
  $self->app->secrets([ map { $_->secret } @secrets ]);
  $self->app->log->debug('secrets', @{$self->app->secrets});

  # Documentation browser under "/perldoc"
  $self->plugin('PODRenderer');
  $self->plugin('OpenQA::Helpers');
  $self->plugin('OpenQA::CSRF');
  $self->plugin('OpenQA::REST');

  # set secure flag on cookies of https connections
  $self->app->hook(before_dispatch => sub {
      my $c = shift;
      #$c->app->log->debug(sprintf "this connection is %ssecure", $c->req->is_secure?'':'NOT ');
      if ($c->req->is_secure) {
	$c->app->sessions->secure(1);
      }
    });

  $self->_read_config;

  if ($self->config->{'logging'}->{'file'}) {
    $self->log->path($self->config->{'logging'}->{'file'});
  }
  if ($self->config->{'logging'}->{'level'}) {
    $self->log->level($self->config->{'logging'}->{'level'});
  }

  # Router
  my $r = $self->routes;
  my $auth = $r->bridge('/')->to("session#ensure_operator");

  $r->get('/session/new')->to('session#new');
  $r->post('/session')->to('session#create');
  $r->delete('/session')->to('session#destroy');
  $r->get('/login')->name('login')->to('session#create');
  $r->post('/login')->to('session#create');
  $r->delete('/logout')->name('logout')->to('session#destroy');
  $r->get('/response')->to('session#response');
  $auth->get('/session/test')->to('session#test');

  my $apik_auth = $auth->route('/api_keys');
  $apik_auth->get('/')->name('api_keys')->to('api_key#index');
  $apik_auth->post('/')->to('api_key#create');
  $apik_auth->delete('/:apikeyid')->name('api_key')->to('api_key#destroy');

  $r->get('/tests')->name('tests')->to('test#list');
  my $test_r = $r->route('/tests/#testid');
  my $test_auth = $auth->route('/tests/#testid');
  $test_r->get('/')->name('test')->to('test#show');

  $test_r->get('/modlist')->name('modlist')->to('running#modlist');
  $test_r->get('/status')->name('status')->to('running#status');
  $test_r->get('/livelog')->name('livelog')->to('running#livelog');
  $test_r->get('/streaming')->name('streaming')->to('running#streaming');
  $test_r->get('/edit')->name('edit_test')->to('running#edit');

  $test_auth->post('/cancel')->name('cancel')->to('schedule#cancel');
  $test_auth->post('/restart')->name('restart')->to('schedule#restart');
  $test_auth->post('/setpriority/:priority')->name('setpriority')->to('schedule#setpriority');
  $test_auth->post('/uploadlog/#filename')->name('uploadlog')->to('test#uploadlog');

  $test_r->get('/images/:filename')->name('test_img')->to('file#test_file');
  $test_r->get('/file/:filename')->name('test_file')->to('file#test_file');
  $test_r->get('/logfile/:filename')->name('test_logfile')->to('file#test_logfile');
  $test_r->get('/diskimages/:imageid')->name('diskimage')->to('file#test_diskimage');

  my $asset_r = $test_r->route('/modules/:moduleid/steps/:stepid', stepid => qr/[1-9]\d*/)->to(controller => 'step');
  my $asset_auth = $auth->route('/modules/:moduleid/steps/:stepid', stepid => qr/[1-9]\d*/);
  $asset_r->get('/view')->to(action => 'view');
  $asset_r->get('/edit')->name('edit_step')->to(action => 'edit');
  $asset_r->get('/src')->name('src_step')->to(action => 'src');
  $asset_auth->post('/')->name('save_needle')->to(action => 'step#save_needle');
  $asset_r->get('/')->name('step')->to(action => 'view');

  $r->get('/builds/#buildid')->name('build')->to('build#show');

  $r->get('/needles/:distri/#name')->name('needle_file')->to('file#needle');

  # Favicon
  $r->get('/favicon.ico' => sub {my $c = shift; $c->render_static('favicon.ico') });
  # Default route
  $r->get('/')->name('index')->to('index#index');

  ### JSON API starts here
  my $api_auth = $r->bridge('/api/v1')->to(controller => 'API::V1', action => 'auth');
  my $api_r = $api_auth->route('/')->to(namespace => 'OpenQA::API::V1');

  # api/v1/jobs
  $api_r->get('/jobs')->name('apiv1_jobs')->to('job#list'); # list_jobs
  $api_r->post('/jobs')->name('apiv1_create_job')->to('job#create'); # job_create
  my $job_r = $api_r->route('/jobs/:jobid', jobid => qr/\d+/);
  $job_r->get('/')->name('apiv1_job')->to('job#show'); # job_get
  $job_r->delete('/')->name('apiv1_delete_job')->to('job#destroy'); # job_delete
  $job_r->post('/prio')->name('apiv1_job_prio')->to('job#prio'); # job_set_prio
  $job_r->post('/result')->name('apiv1_job_result')->to('job#result'); # job_update_result
  $job_r->post('/set_done')->name('apiv1_set_done')->to('job#done'); # job_set_done
  # job_set_scheduled, job_set_cancel, job_set_waiting, job_set_continue
  my $command_r = $job_r->route('/set_:command', command => [qw(waiting continue)]);
  $command_r->post('/')->name('apiv1_set_command')->to('job#set_command');
  # restart and cancel are valid both by job id or by job name (which is
  # exactly the same, but with less restrictive format)
  my $job_name_r = $api_r->route('/jobs/#name');
  $job_r->post('/restart')->name('apiv1_restart_job')->to('job#restart'); # job_restart
  $job_r->post('/cancel')->name('apiv1_cancel')->to('job#cancel'); # job_cancel
  $job_r->post('/duplicate')->name('apiv1_duplicate')->to('job#duplicate'); # job_duplicate

  # api/v1/workers
  $api_r->get('/workers')->name('apiv1_workers')->to('worker#list'); # list_workers
  $api_r->post('/workers')->name('apiv1_create_worker')->to('worker#create'); # worker_register
  my $worker_r = $api_r->route('/workers/:workerid', workerid => qr/\d+/);
  $worker_r->get('/')->name('apiv1_worker')->to('worker#show'); # worker_get
  $worker_r->get('/commands/')->name('apiv1_commands')->to('command#list'); #command_get
  $worker_r->post('/commands/')->name('apiv1_create_command')->to('command#create'); #command_enqueue
  $worker_r->delete('/commands/:commandid')->name('apiv1_delete_command')->to('command#destroy'); #command_dequeue
  $worker_r->post('/grab_job')->name('apiv1_grab_job')->to('job#grab'); # job_grab

  # api/v1/isos
  $api_r->post('/isos')->name('apiv1_create_iso')->to('iso#create'); # iso_new
  $api_r->delete('/isos/#name')->name('apiv1_destroy_iso')->to('iso#destroy'); # iso_delete
  $api_r->post('/isos/#name/cancel')->name('apiv1_cancel_iso')->to('iso#cancel'); # iso_cancel

  # json-rpc methods not migrated to this api: echo, list_commands
  ### JSON API ends here

  # start workers checker
  $self->_workers_checker;
}

1;
