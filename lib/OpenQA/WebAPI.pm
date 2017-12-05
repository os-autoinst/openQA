# Copyright (C) 2015-2016 SUSE LLC
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
# with this program; if not, see <http://www.gnu.org/licenses/>.

package OpenQA::WebAPI;
use strict;

# https://github.com/rurban/Cpanel-JSON-XS/issues/65
use JSON::PP;

use Mojolicious 7.18;
use Mojo::Base 'Mojolicious';
use OpenQA::Schema;
use OpenQA::WebAPI::Plugin::Helpers;
use OpenQA::IPC;
use OpenQA::Utils qw(log_warning job_groups_and_parents detect_current_version);
use OpenQA::Setup;
use Mojo::IOLoop;
use Mojolicious::Commands;
use DateTime;
use Cwd 'abs_path';
use File::Path 'make_path';
use BSD::Resource 'getrusage';

# reinit pseudo random number generator in every child to avoid
# starting off with the same state.
sub _init_rand {
    my $self = shift;
    return unless $ENV{HYPNOTOAD_APP};
    Mojo::IOLoop->timer(
        0 => sub {
            srand;
            $self->app->log->debug("initialized random number generator in $$");
        });
}

has schema => sub {
    return OpenQA::Schema::connect_db();
};

has secrets => sub {
    my $self = shift;
    # read application secret from database
    # we cannot use our own schema here as we must not actually
    # initialize the db connection here. Would break for prefork.
    my @secrets = $self->schema->resultset('Secrets')->all();
    if (!@secrets) {
        # create one if it doesn't exist
        $self->schema->resultset('Secrets')->create({});
        @secrets = $self->schema->resultset('Secrets')->all();
    }
    die "couldn't create secrets\n" unless @secrets;
    my $ret = [map { $_->secret } @secrets];
    return $ret;
};

sub log_name {
    return $$;
}

# This method will run once at server start
sub startup {
    my $self = shift;
    OpenQA::Setup::read_config($self);
    OpenQA::Setup::setup_log($self);

    # Set some application defaults
    $self->defaults(appname         => $self->app->config->{global}->{appname});
    $self->defaults(current_version => detect_current_version($self->app->home));

    unless ($ENV{MOJO_TMPDIR}) {
        $ENV{MOJO_TMPDIR} = $OpenQA::Utils::assetdir . '/tmp';
        # Try to create tmpdir if it doesn't exist but don't die if failed to create
        if (!-e $ENV{MOJO_TMPDIR}) {
            eval { make_path($ENV{MOJO_TMPDIR}); };
            if ($@) {
                print STDERR "Can not create MOJO_TMPDIR : $@\n";
            }
        }
        delete $ENV{MOJO_TMPDIR} unless -w $ENV{MOJO_TMPDIR};
    }

    # take care of DB deployment or migration before starting the main app
    my $schema = OpenQA::Schema::connect_db;

    unshift @{$self->renderer->paths}, '/etc/openqa/templates';

    # Load plugins
    push @{$self->plugins->namespaces}, 'OpenQA::WebAPI::Plugin';
    $self->plugin(AssetPack => {pipes => [qw(Sass Css JavaScript Fetch OpenQA::WebAPI::AssetPipe Combine)]});

    foreach my $plugin (qw(Helpers CSRF REST HashedParams Gru)) {
        $self->plugin($plugin);
    }

    if ($self->config->{global}{audit_enabled}) {
        $self->plugin('AuditLog', Mojo::IOLoop->singleton);
    }
    # Load arbitrary plugins defined in config: 'plugins' in section
    # '[global]' can be a space-separated list of plugins to load, by
    # module name under OpenQA::WebAPI::Plugin::
    if (defined $self->config->{global}->{plugins}) {
        my @plugins = split(' ', $self->config->{global}->{plugins});
        for my $plugin (@plugins) {
            $self->log->info("Loading external plugin $plugin");
            $self->plugin($plugin);
        }
    }
    if ($self->config->{global}{profiling_enabled}) {
        $self->plugin(NYTProf => {nytprof => {}});
    }
    # load auth module
    my $auth_method = $self->config->{auth}->{method};
    my $auth_module = "OpenQA::WebAPI::Auth::$auth_method";
    eval "require $auth_module";    ## no critic
    if ($@) {
        die sprintf('Unable to load auth module %s for method %s', $auth_module, $auth_method);
    }

    # Read configurations expected by plugins.
    OpenQA::Setup::update_config($self->config, @{$self->plugins->namespaces}, "OpenQA::WebAPI::Auth");

    # End plugin loading/handling

    # read assets/assetpack.def
    $self->asset->process;

    # set cookie timeout to 48 hours (will be updated on each request)
    $self->app->sessions->default_expiration(48 * 60 * 60);

    # set secure flag on cookies of https connections
    $self->hook(
        before_dispatch => sub {
            my $c = shift;
            #$c->app->log->debug(sprintf "this connection is %ssecure", $c->req->is_secure?'':'NOT ');
            if ($c->req->is_secure) {
                $c->app->sessions->secure(1);
            }
            if (my $days = $c->app->config->{global}->{hsts}) {
                $c->res->headers->header(
                    'Strict-Transport-Security' => sprintf('max-age=%d; includeSubDomains', $days * 24 * 60 * 60));
            }
            $c->stash('job_groups_and_parents', job_groups_and_parents);
        });

    # Mark build_tx time in the header for HMAC time stamp check
    # to avoid large timeouts on uploads
    $self->hook(
        after_build_tx => sub {
            my ($tx, $app) = @_;
            $tx->req->headers->header('X-Build-Tx-Time' => time);
        });

    # Router
    my $r         = $self->routes;
    my $logged_in = $r->under('/')->to("session#ensure_user");
    my $auth      = $r->under('/')->to("session#ensure_operator");
    my %api_description;

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
    $r->get('/tests/overview')->name('tests_overview')->to('test#overview');
    $r->get('/tests/latest')->name('latest')->to('test#latest');

    $r->get('/tests/export')->name('tests_export')->to('test#export');
    $r->post('/tests/list_ajax')->name('tests_ajax')->to('test#list_ajax');

    # only provide a URL helper - this is overtaken by apache
    $r->get('/assets/*assetpath')->name('download_asset')->to('file#download_asset');

    my $test_r = $r->route('/tests/:testid', testid => qr/\d+/);
    $test_r = $test_r->under('/')->to('test#referer_check');
    my $test_auth = $auth->route('/tests/:testid', testid => qr/\d+/, format => 0);
    $test_r->get('/')->name('test')->to('test#show');
    $test_r->get('/modules/:moduleid/fails')->name('test_module_fails')->to('test#module_fails');

    $test_r->get('/details')->name('details')->to('test#details');
    $test_r->get('/status')->name('status')->to('running#status');
    $test_r->get('/livelog')->name('livelog')->to('running#livelog');
    $test_r->get('/liveterminal')->name('liveterminal')->to('running#liveterminal');
    $test_r->get('/streaming')->name('streaming')->to('running#streaming');
    $test_r->get('/edit')->name('edit_test')->to('running#edit');

    $test_r->get('/images/#filename')->name('test_img')->to('file#test_file');
    $test_r->get('/images/thumb/#filename')->name('test_thumbnail')->to('file#test_thumbnail');
    $test_r->get('/file/#filename')->name('test_file')->to('file#test_file');
    $test_r->get('/iso')->name('isoimage')->to('file#test_isoimage');
    # adding assetid => qr/\d+/ doesn't work here. wtf?
    $test_r->get('/asset/#assetid')->name('test_asset_id')->to('file#test_asset');
    $test_r->get('/asset/#assettype/#assetname')->name('test_asset_name')->to('file#test_asset');
    $test_r->get('/asset/#assettype/#assetname/*subpath')->name('test_asset_name_path')->to('file#test_asset');

    my $step_r = $test_r->route('/modules/:moduleid/steps/:stepid', stepid => qr/[1-9]\d*/)->to(controller => 'step');
    my $step_auth = $test_auth->route('/modules/:moduleid/steps/:stepid', stepid => qr/[1-9]\d*/);
    $step_r->get('/view')->to(action => 'view');
    $step_r->get('/edit')->name('edit_step')->to(action => 'edit');
    $step_r->get('/src')->name('src_step')->to(action => 'src');
    $step_auth->post('/')->name('save_needle_ajax')->to('step#save_needle_ajax');
    $step_r->get('/')->name('step')->to(action => 'view');

    $r->get('/needles/:distri/#name')->name('needle_file')->to('file#needle');
    # this route is used in the helper
    $r->get('/image/:md5_dirname/.thumbs/#md5_basename')->name('thumb_image')->to('file#thumb_image');
    # but this route is actually matched (in case apache is not catching this earlier)
    # due to the split md5_dirname having a /
    $r->get('/image/:md5_1/:md5_2/.thumbs/#md5_basename')->to('file#thumb_image');

    $r->get('/group_overview/:groupid')->name('group_overview')->to('main#job_group_overview');
    $r->get('/parent_group_overview/:groupid')->name('parent_group_overview')->to('main#parent_group_overview');

    # Favicon
    $r->get('/favicon.ico' => sub { my $c = shift; $c->render_static('favicon.ico') });
    $r->get('/index' => [format => ['html', 'json']])->to('main#index');
    $r->get('/api_help' => sub { shift->render('admin/api_help') })->name('api_help');

    # Default route
    $r->get('/')->name('index')->to('main#index');
    $r->get('/changelog')->name('changelog')->to('main#changelog');

    # shorter version of route to individual job results
    $r->get('/t:testid' => sub { shift->redirect_to('test') });

    # Redirection for old links to openQAv1
    $r->get(
        '/results' => sub {
            my $c = shift;
            $c->redirect_to('tests');
        });

    #
    ## Admin area starts here
    ###
    my $admin_auth  = $r->under('/admin')->to('session#ensure_admin');
    my $admin_r     = $admin_auth->route('/')->to(namespace => 'OpenQA::WebAPI::Controller::Admin');
    my $op_auth     = $r->under('/admin')->to('session#ensure_operator');
    my $op_r        = $op_auth->route('/')->to(namespace => 'OpenQA::WebAPI::Controller::Admin');
    my $pub_admin_r = $r->route('/admin')->to(namespace => 'OpenQA::WebAPI::Controller::Admin');

    # operators accessible tables
    $pub_admin_r->get('/products')->name('admin_products')->to('product#index');
    $pub_admin_r->get('/machines')->name('admin_machines')->to('machine#index');
    $pub_admin_r->get('/test_suites')->name('admin_test_suites')->to('test_suite#index');

    $pub_admin_r->get('/job_templates/:groupid')->name('admin_job_templates')->to('job_template#index');

    $pub_admin_r->get('/groups')->name('admin_groups')->to('job_group#index');
    $pub_admin_r->get('/job_group/:groupid')->name('admin_job_group_row')->to('job_group#job_group_row');
    $pub_admin_r->get('/parent_group/:groupid')->name('admin_parent_group_row')->to('job_group#parent_group_row');
    $pub_admin_r->get('/edit_parent_group/:groupid')->name('admin_edit_parent_group')
      ->to('job_group#edit_parent_group');
    $pub_admin_r->get('/groups/connect/:groupid')->name('job_group_new_media')->to('job_group#connect');

    $pub_admin_r->get('/assets')->name('admin_assets')->to('asset#index');

    $pub_admin_r->get('/workers')->name('admin_workers')->to('workers#index');
    $pub_admin_r->get('/workers/:worker_id')->name('admin_worker_show')->to('workers#show');
    $pub_admin_r->get('/workers/:worker_id/ajax')->name('admin_worker_previous_jobs_ajax')
      ->to('workers#previous_jobs_ajax');

    $pub_admin_r->get('/productlog')->name('admin_product_log')->to('audit_log#productlog');

    # admins accessible tables
    $admin_r->get('/users')->name('admin_users')->to('user#index');
    $admin_r->post('/users/:userid')->name('admin_user')->to('user#update');
    $admin_r->get('/needles')->name('admin_needles')->to('needle#index');
    $admin_r->get('/needles/:module_id/:needle_id')->name('admin_needle_module')->to('needle#module');
    $admin_r->get('/needles/ajax')->name('admin_needle_ajax')->to('needle#ajax');
    $admin_r->delete('/needles/delete')->name('admin_needle_delete')->to('needle#delete');
    $admin_r->get('/auditlog')->name('audit_log')->to('audit_log#index');
    $admin_r->get('/auditlog/ajax')->name('audit_ajax')->to('audit_log#ajax');
    $admin_r->post('/groups/connect/:groupid')->name('job_group_save_media')->to('job_group#save_connect');

    # Workers list as default option
    $op_r->get('/')->name('admin')->to('workers#index');
    ###
    ## Admin area ends here
    #

    #
    ## JSON API starts here
    ###
    my $api_auth_any_user = $r->under('/api/v1')->to(controller => 'API::V1', action => 'auth');
    my $api_auth_operator = $r->under('/api/v1')->to(controller => 'API::V1', action => 'auth_operator');
    my $api_auth_admin    = $r->under('/api/v1')->to(controller => 'API::V1', action => 'auth_admin');
    my $api_ru = $api_auth_any_user->route('/')->to(namespace => 'OpenQA::WebAPI::Controller::API::V1');
    my $api_ro = $api_auth_operator->route('/')->to(namespace => 'OpenQA::WebAPI::Controller::API::V1');
    my $api_ra = $api_auth_admin->route('/')->to(namespace => 'OpenQA::WebAPI::Controller::API::V1');
    my $api_public_r = $r->route('/api/v1')->to(namespace => 'OpenQA::WebAPI::Controller::API::V1');
    # this is fallback redirect if one does not use apache
    $api_public_r->websocket(
        '/ws/:workerid' => sub {
            my $c        = shift;
            my $workerid = $c->param('workerid');
            # use port one higher than WebAPI
            my $port = 9527;
            if ($ENV{MOJO_LISTEN} =~ /.*:(\d{1,5})\/?$/) {
                $port = $1 + 1;
            }
            $c->redirect_to("http://localhost:$port/ws/$workerid");
        });
    my $api_job_auth = $r->under('/api/v1')->to(controller => 'API::V1', action => 'auth_jobtoken');
    my $api_r_job = $api_job_auth->route('/')->to(namespace => 'OpenQA::WebAPI::Controller::API::V1');
    $api_r_job->get('/whoami')->name('apiv1_jobauth_whoami')->to('job#whoami');    # primarily for tests

    # api/v1/job_groups
    $api_public_r->get('/job_groups')->name('apiv1_list_job_groups')->to('job_group#list');
    $api_public_r->get('/job_groups/:group_id')->name('apiv1_get_job_group')->to('job_group#list');
    $api_public_r->get('/job_groups/:group_id/jobs')->name('apiv1_get_job_group_jobs')->to('job_group#list_jobs');
    $api_ra->post('/job_groups')->name('apiv1_post_job_group')->to('job_group#create');
    $api_ra->put('/job_groups/:group_id')->name('apiv1_put_job_group')->to('job_group#update');
    $api_ra->delete('/job_groups/:group_id')->name('apiv1_delete_job_group')->to('job_group#delete');

    # api/v1/parent_groups
    $api_public_r->get('/parent_groups')->name('apiv1_list_parent_groups')->to('job_group#list');
    $api_public_r->get('/parent_groups/:group_id')->name('apiv1_get_parent_group')->to('job_group#list');
    $api_ra->post('/parent_groups')->name('apiv1_post_parent_group')->to('job_group#create');
    $api_ra->put('/parent_groups/:group_id')->name('apiv1_put_parent_group')->to('job_group#update');
    $api_ra->delete('/parent_groups/:group_id')->name('apiv1_delete_parent_group')->to('job_group#delete');

    # api/v1/jobs
    $api_public_r->get('/jobs')->name('apiv1_jobs')->to('job#list');
    $api_ro->post('/jobs')->name('apiv1_create_job')->to('job#create');
    $api_ro->post('/jobs/cancel')->name('apiv1_cancel_jobs')->to('job#cancel');
    $api_ro->post('/jobs/restart')->name('apiv1_restart_jobs')->to('job#restart');

    my $job_r = $api_ro->route('/jobs/:jobid', jobid => qr/\d+/);
    $api_public_r->route('/jobs/:jobid', jobid => qr/\d+/)->name('apiv1_job')->to('job#show');
    $api_public_r->route('/jobs/:jobid/details', jobid => qr/\d+/)->name('apiv1_job')->to('job#show', details => 1);
    $job_r->put('/')->name('apiv1_put_job')->to('job#update');
    $job_r->delete('/')->name('apiv1_delete_job')->to('job#destroy');
    $job_r->post('/prio')->name('apiv1_job_prio')->to('job#prio');
    $job_r->post('/set_done')->name('apiv1_set_done')->to('job#done');
    $job_r->post('/status')->name('apiv1_update_status')->to('job#update_status');
    $job_r->post('/artefact')->name('apiv1_create_artefact')->to('job#create_artefact');
    $job_r->post('/ack_temporary')->to('job#ack_temporary');


    # job_set_waiting, job_set_continue
    my $command_r = $job_r->route('/set_:command', command => [qw(waiting running)]);
    $command_r->post('/')->name('apiv1_set_command')->to('job#set_command');
    $job_r->post('/restart')->name('apiv1_restart')->to('job#restart');
    $job_r->post('/cancel')->name('apiv1_cancel')->to('job#cancel');
    $job_r->post('/duplicate')->name('apiv1_duplicate')->to('job#duplicate');

    # api/v1/bugs
    $api_public_r->get('/bugs')->name('apiv1_bugs')->to('bug#list');
    $api_ro->post('/bugs')->name('apiv1_create_bug')->to('bug#create');
    my $bug_r = $api_ro->route('/bugs/:id', bid => qr/\d+/);
    $bug_r->get('/')->name('apiv1_show_bug')->to('bug#show');
    $bug_r->put('/')->name('apiv1_put_bug')->to('bug#update');
    $bug_r->delete('/')->name('apiv1_delete_bug')->to('bug#destroy');

    # api/v1/workers
    $api_public_r->get('/workers')->name('apiv1_workers')->to('worker#list');
    $api_description{'apiv1_worker'}
      = 'Each entry contains the "hostname", the boolean flag "connected" which can be 0 or 1 depending on the connection to the websockets server and the field "status" which can be "dead", "idle", "running". A worker can be considered "up" when "connected=1" and "status!=dead"';
    $api_ro->post('/workers')->name('apiv1_create_worker')->to('worker#create');
    my $worker_r = $api_ro->route('/workers/:workerid', workerid => qr/\d+/);
    $api_public_r->route('/workers/:workerid', workerid => qr/\d+/)->get('/')->name('apiv1_worker')->to('worker#show');
    $worker_r->post('/commands/')->name('apiv1_create_command')->to('command#create');

    # redirect for older workers
    $worker_r->websocket(
        '/ws' => sub {
            my $c        = shift;
            my $workerid = $c->param('workerid');
            # use port one higher than WebAPI
            my $port = 9527;
            if (defined $ENV{MOJO_LISTEN} && $ENV{MOJO_LISTEN} =~ /.*:(\d{1,5})\/?$/) {
                $port = $1 + 1;
            }
            $c->redirect_to("http://localhost:$port/ws/$workerid");
        });

    # api/v1/mutex
    $api_r_job->post('/mutex')->name('apiv1_mutex_create')->to('locks#mutex_create');
    $api_r_job->post('/mutex/:name')->name('apiv1_mutex_action')->to('locks#mutex_action');
    # api/v1/barriers/
    $api_r_job->post('/barrier')->name('apiv1_barrier_create')->to('locks#barrier_create');
    $api_r_job->post('/barrier/:name', [name => qr/[0-9a-zA-Z_]+/])->name('apiv1_barrier_wait')
      ->to('locks#barrier_wait');
    $api_r_job->delete('/barrier/:name', [name => qr/[0-9a-zA-Z_]+/])->name('apiv1_barrier_destroy')
      ->to('locks#barrier_destroy');

    # api/v1/mm
    my $mm_api = $api_r_job->route('/mm');
    $mm_api->get('/children/:status' => [status => [qw(running scheduled done)]])->name('apiv1_mm_running_children')
      ->to('mm#get_children_status');
    $mm_api->get('/children')->name('apiv1_mm_children')->to('mm#get_children');
    $mm_api->get('/parents')->name('apiv1_mm_parents')->to('mm#get_parents');

    # api/v1/isos
    $api_ro->post('/isos')->name('apiv1_create_iso')->to('iso#create');
    $api_ra->delete('/isos/#name')->name('apiv1_destroy_iso')->to('iso#destroy');
    $api_ro->post('/isos/#name/cancel')->name('apiv1_cancel_iso')->to('iso#cancel');

    # api/v1/assets
    $api_ro->post('/assets')->name('apiv1_post_asset')->to('asset#register');
    $api_public_r->get('/assets')->name('apiv1_get_asset')->to('asset#list');
    $api_public_r->get('/assets/#id')->name('apiv1_get_asset_id')->to('asset#get');
    $api_public_r->get('/assets/#type/#name')->name('apiv1_get_asset_name')->to('asset#get');
    $api_ra->delete('/assets/#id')->name('apiv1_delete_asset')->to('asset#delete');
    $api_ra->delete('/assets/#type/#name')->name('apiv1_delete_asset_name')->to('asset#delete');

    # api/v1/test_suites
    $api_public_r->get('test_suites')->name('apiv1_test_suites')->to('table#list', table => 'TestSuites');
    $api_ra->post('test_suites')->to('table#create', table => 'TestSuites');
    $api_public_r->get('test_suites/:id')->name('apiv1_test_suite')->to('table#list', table => 'TestSuites');
    $api_ra->put('test_suites/:id')->to('table#update', table => 'TestSuites');
    $api_ra->post('test_suites/:id')->to('table#update', table => 'TestSuites');    #in case PUT is not supported
    $api_ra->delete('test_suites/:id')->to('table#destroy', table => 'TestSuites');

    # api/v1/machines
    $api_public_r->get('machines')->name('apiv1_machines')->to('table#list', table => 'Machines');
    $api_ra->post('machines')->to('table#create', table => 'Machines');
    $api_public_r->get('machines/:id')->name('apiv1_machine')->to('table#list', table => 'Machines');
    $api_ra->put('machines/:id')->to('table#update', table => 'Machines');
    $api_ra->post('machines/:id')->to('table#update', table => 'Machines');         #in case PUT is not supported
    $api_ra->delete('machines/:id')->to('table#destroy', table => 'Machines');

    # api/v1/products
    $api_public_r->get('products')->name('apiv1_products')->to('table#list', table => 'Products');
    $api_ra->post('products')->to('table#create', table => 'Products');
    $api_public_r->get('products/:id')->name('apiv1_product')->to('table#list', table => 'Products');
    $api_ra->put('products/:id')->to('table#update', table => 'Products');
    $api_ra->post('products/:id')->to('table#update', table => 'Products');         #in case PUT is not supported
    $api_ra->delete('products/:id')->to('table#destroy', table => 'Products');

    # api/v1/job_templates
    $api_public_r->get('job_templates')->name('apiv1_job_templates')->to('job_template#list');
    $api_ra->post('job_templates')->to('job_template#create');
    $api_public_r->get('job_templates/:job_template_id')->name('apiv1_job_template')->to('job_template#list');
    $api_ra->delete('job_templates/:job_template_id')->to('job_template#destroy');

    # api/v1/comments
    $api_public_r->get('/jobs/:job_id/comments')->name('apiv1_list_comments')->to('comment#list');
    $api_public_r->get('/jobs/:job_id/comments/:comment_id')->name('apiv1_get_comment')->to('comment#text');
    $api_ru->post('/jobs/:job_id/comments')->name('apiv1_post_comment')->to('comment#create');
    $api_ru->put('/jobs/:job_id/comments/:comment_id')->name('apiv1_put_comment')->to('comment#update');
    $api_ra->delete('/jobs/:job_id/comments/:comment_id')->name('apiv1_delete_comment')->to('comment#delete');
    $api_public_r->get('/groups/:group_id/comments')->name('apiv1_list_group_comment')->to('comment#list');
    $api_public_r->get('/groups/:group_id/comments/:comment_id')->name('apiv1_get_group_comment')->to('comment#text');
    $api_ru->post('/groups/:group_id/comments')->name('apiv1_post_group_comment')->to('comment#create');
    $api_ru->put('/groups/:group_id/comments/:comment_id')->name('apiv1_put_group_comment')->to('comment#update');
    $api_ra->delete('/groups/:group_id/comments/:comment_id')->name('apiv1_delete_group_comment')->to('comment#delete');

    # json-rpc methods not migrated to this api: echo, list_commands
    ###
    ## JSON API ends here
    #

    # api/v1/feature
    $api_ru->post('/feature')->name('apiv1_post_informed_about')->to('feature#informed');
    $api_description{'apiv1_post_informed_about'}
      = 'Post integer value to save feature tour progress of current user in the database';

    # reduce_result is obsolete (replaced by limit_results_and_logs)
    $self->gru->add_task(reduce_result          => \&OpenQA::Schema::Result::Jobs::reduce_result);
    $self->gru->add_task(limit_assets           => \&OpenQA::Schema::Result::Assets::limit_assets);
    $self->gru->add_task(limit_results_and_logs => \&OpenQA::Schema::Result::JobGroups::limit_results_and_logs);
    $self->gru->add_task(download_asset         => \&OpenQA::Schema::Result::Assets::download_asset);
    $self->gru->add_task(scan_old_jobs          => \&OpenQA::Schema::Result::Needles::scan_old_jobs);
    $self->gru->add_task(scan_needles           => \&OpenQA::Schema::Result::Needles::scan_needles);
    $self->gru->add_task(migrate_images         => \&OpenQA::Schema::Result::JobModules::migrate_images);
    $self->gru->add_task(relink_testresults     => \&OpenQA::Schema::Result::JobModules::relink_testresults);
    $self->gru->add_task(rm_compat_symlinks     => \&OpenQA::Schema::Result::JobModules::rm_compat_symlinks);
    $self->gru->add_task(scan_images            => \&OpenQA::Schema::Result::Screenshots::scan_images);
    $self->gru->add_task(scan_images_links      => \&OpenQA::Schema::Result::Screenshots::scan_images_links);

    $self->validator->add_check(
        datetime => sub {
            my ($validation, $name, $value) = @_;
            eval { DateTime::Format::Pg->parse_datetime($value); };
            if ($@) {
                return 1;
            }
            return;
        });

    $self->_add_memory_limit;
    $self->_init_rand;

    # run fake dbus services in case of test mode
    if ($self->mode eq 'test' && !$ENV{FULLSTACK}) {
        log_warning('Running in test mode - dbus services mocked');
        require OpenQA::WebSockets;
        require OpenQA::Scheduler;
        require OpenQA::ResourceAllocator;
        OpenQA::WebSockets->new;
        OpenQA::Scheduler->new;
        OpenQA::ResourceAllocator->new;
    }

    # add method to be called before rendering
    $self->app->hook(
        before_render => sub {
            my ($c, $args) = @_;
            # return errors as JSON if accepted but HTML not
            if (!$c->accepts('html') && $c->accepts('json') && $args->{status} && $args->{status} != 200) {
                # the JSON API might already provide JSON in some error cases which must be preserved
                (($args->{json} //= {})->{error_status}) = $args->{status};
            }
            $c->stash('api_description', \%api_description);
        });
}

# Stop prefork workers gracefully once they reach a certain size
sub _add_memory_limit {
    my ($self) = @_;

    my $max = $self->config->{global}{max_rss_limit};
    return unless $max && $max > 0;

    my $parent = $$;
    Mojo::IOLoop->next_tick(
        sub {
            Mojo::IOLoop->recurring(
                5 => sub {
                    my $rss = (getrusage())[2];
                    # RSS is in KB under Linux
                    return unless $rss > $max;
                    $self->log->debug(qq{Worker exceeded RSS limit "$rss > $max", restarting});
                    Mojo::IOLoop->stop_gracefully;
                }) if $parent ne $$;
        });
}

sub run {
    # Start command line interface for application
    Mojolicious::Commands->start_app('OpenQA::WebAPI');
}

1;
# vim: set sw=4 et:
