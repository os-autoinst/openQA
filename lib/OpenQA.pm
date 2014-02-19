package OpenQA;
use Mojo::Base 'Mojolicious';
use OpenQA::Helpers;

use Config::IniFiles;

sub _rndstr {
    my $length = shift || 16;
    my $str;
    my @chars = ('a'..'z', 'A'..'Z', '0'..'9', '_');
    foreach (1..$length) {
	$str .= $chars[rand @chars];
    }
    return $str;
}

sub _read_config {
  my $self = shift;

  my $defaults = {
    needles_scm => 'git',
    needles_git_worktree => '/var/lib/os-autoinst/needles',
    needles_git_do_push => 'no',
    openid_secret => _rndstr(16),
  };

  # Mojo's built in config plugins suck. JSON for example does not
  # support comments
  my $cfg = Config::IniFiles->new( -fallback => 'global',
      -file => $ENV{OPENQA_CONFIG} || $self->app->home.'/lib/openqa.ini') || undef;

  for my $k (qw/
      needles_scm
      needles_git_worktree
      needles_git_do_push
      allowed_hosts
      suse_mirror
      openid_secret
      base_url
      /) {
    my $v = $cfg && $cfg->val('global', $k) || $defaults->{$k};
    $self->app->config->{$k} = $v if $v;
  }
}


# This method will run once at server start
sub startup {
  my $self = shift;

  # Set some application defaults
  $self->defaults( appname => 'openQA' );

  # Documentation browser under "/perldoc"
  $self->plugin('PODRenderer');
  $self->plugin('OpenQA::Helpers');

  $self->_read_config;

  # Router
  my $r = $self->routes;

  $r->get('/login')->name('login')->to('login#login');
  $r->get('/response')->to('login#response');

  my $auth = $r->bridge('secret')->to("login#auth");
  $auth->get('/test')->to('#test');

  $r->get('/tests')->name('tests')->to('test#list');
  my $test_r = $r->route('/tests/#testid');
  $test_r->get('/')->name('test')->to('test#show');

  $test_r->get('/modlist')->name('modlist')->to('running#modlist');
  $test_r->get('/status')->name('status')->to('running#status');
  $test_r->get('/livelog')->name('livelog')->to('running#livelog');
  $test_r->get('/streaming')->name('streaming')->to('running#streaming');
  $test_r->get('/edit')->name('edit_test')->to('running#edit');

  $test_r->post('/cancel')->name('cancel')->to('schedule#cancel');
  $test_r->post('/restart')->name('restart')->to('schedule#restart');
  $test_r->post('/setpriority/:priority')->name('setpriority')->to('schedule#setpriority');
  $test_r->post('/uploadlog/#filename')->name('uploadlog')->to('test#uploadlog');

  $test_r->get('/images/:filename')->name('test_img')->to('file#test_file');
  $test_r->get('/file/:filename')->name('test_file')->to('file#test_file');
  $test_r->get('/logfile/:filename')->name('test_logfile')->to('file#test_logfile');
  $test_r->get('/diskimages/:imageid')->name('diskimage')->to('file#test_diskimage');

  my $asset_r = $test_r->route('/modules/:moduleid/steps/:stepid', stepid => qr/[1-9]\d*/)->to(controller => 'step');
  $asset_r->get('/view')->to(action => 'view');
  $asset_r->get('/edit')->name('edit_step')->to(action => 'edit');
  $asset_r->get('/src')->name('src_step')->to(action => 'src');
  $asset_r->post('/')->name('save_needle')->to(action => 'save_needle');
  $asset_r->get('/')->name('step')->to(action => 'view');

  $r->get('/builds/#buildid')->name('build')->to('build#show');

  $r->get('/needles/:distri/#name')->name('needle_file')->to('file#needle');

  # Favicon
  $r->get('/favicon.ico' => sub {my $c = shift; $c->render_static('favicon.ico') });
  # Default route
  $r->get('/')->name('index')->to('index#index');

  ### JSON API starts here
  my $api_r = $r->route('/api/v1')->to(namespace => 'OpenQA::API::V1');

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
  my $command_r = $job_r->route('/set_:command', command => [qw(scheduled cancel waiting continue)]);
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

}

1;
