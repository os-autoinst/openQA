# Copyright (C) 2015-2019 SUSE LLC
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
use Mojo::Base 'Mojolicious';

use Mojolicious 7.18;
use OpenQA::Schema;
use OpenQA::WebAPI::Plugin::Helpers;
use OpenQA::Utils qw(log_warning job_groups_and_parents detect_current_version);
use OpenQA::Setup;
use OpenQA::WebAPI::Description qw(get_pod_from_controllers set_api_desc);
use Mojo::IOLoop;
use Mojolicious::Commands;
use DateTime;
use Cwd 'abs_path';
use File::Path 'make_path';

has secrets => sub {
    my ($self) = @_;
    return $self->schema->read_application_secrets();
};

sub log_name {
    return $$;
}

# This method will run once at server start
sub startup {
    my $self = shift;

    OpenQA::Setup::read_config($self);
    OpenQA::Setup::setup_log($self);
    OpenQA::Setup::setup_app_defaults($self);
    OpenQA::Setup::setup_mojo_tmpdir();
    OpenQA::Setup::add_build_tx_time_header($self);

    # take care of DB deployment or migration before starting the main app
    OpenQA::Schema->singleton;

    # register basic routes
    my $r         = $self->routes;
    my $logged_in = $r->under('/')->to("session#ensure_user");
    my $auth      = $r->under('/')->to("session#ensure_operator");

    # Routes used by plugins (UI and API)
    my $admin_auth = $r->under('/admin')->to('session#ensure_admin')->name('ensure_admin');
    my $op_auth    = $r->under('/admin')->to('session#ensure_operator')->name('ensure_operator');
    my $api_auth_operator
      = $r->under('/api/v1')->to(controller => 'API::V1', action => 'auth_operator')->name('api_ensure_operator');
    my $api_auth_admin
      = $r->under('/api/v1')->to(controller => 'API::V1', action => 'auth_admin')->name('api_ensure_admin');
    my $api_auth_any_user
      = $r->under('/api/v1')->to(controller => 'API::V1', action => 'auth')->name('api_ensure_user');
    my $api_public = $r->route('/api/v1')->name('api_public');

    OpenQA::Setup::setup_template_search_path($self);
    OpenQA::Setup::load_plugins($self, $auth);
    OpenQA::Setup::set_secure_flag_on_cookies_of_https_connection($self);

 # setup asset pack
 # -> in case the following line is moved in another location, script/generate-packed-assets needs to be adapted as well
    $self->plugin(AssetPack => {pipes => [qw(Sass Css JavaScript Fetch OpenQA::WebAPI::AssetPipe Combine)]});
    # -> read assets/assetpack.def
    $self->asset->process;

    # set cookie timeout to 48 hours (will be updated on each request)
    $self->app->sessions->default_expiration(48 * 60 * 60);

    # commands
    push @{$self->commands->namespaces}, 'OpenQA::WebAPI::Command';

    # add actions before dispatching page
    $self->hook(
        before_dispatch => sub {
            my ($controller) = @_;
            OpenQA::Setup::set_secure_flag_on_cookies($controller);
            $controller->stash('job_groups_and_parents', job_groups_and_parents);
        });

    # placeholder types
    $r->add_type(step    => qr/[1-9]\d*/);
    $r->add_type(barrier => qr/[0-9a-zA-Z_]+/);
    $r->add_type(str     => qr/[A-Za-z]+/);

    # register routes
    $r->post('/session')->to('session#create');
    $r->delete('/session')->to('session#destroy');
    $r->get('/login')->name('login')->to('session#create');
    $r->post('/login')->to('session#create');
    $r->delete('/logout')->name('logout')->to('session#destroy');
    $r->get('/logout')->to('session#destroy');
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
    $r->get('/tests/list_ajax')->name('tests_ajax')->to('test#list_ajax');
    $r->get('/tests/list_running_ajax')->name('tests_ajax')->to('test#list_running_ajax');
    $r->get('/tests/list_scheduled_ajax')->name('tests_ajax')->to('test#list_scheduled_ajax');

    # only provide a URL helper - this is overtaken by apache
    $r->get('/assets/*assetpath')->name('download_asset')->to('file#download_asset');

    my $test_r = $r->route('/tests/<testid:num>');
    $test_r = $test_r->under('/')->to('test#referer_check');
    my $test_auth = $auth->route('/tests/<testid:num>', format => 0);
    $test_r->get('/')->name('test')->to('test#show');
    $test_r->get('/ajax')->name('job_next_previous_ajax')->to('test#job_next_previous_ajax');
    $test_r->get('/modules/:moduleid/fails')->name('test_module_fails')->to('test#module_fails');
    $test_r->get('/dependencies')->name('test_dependencies')->to('test#dependencies');
    $test_r->get('/investigation')->name('test_investigation')->to('test#investigate');

    $test_r->get('/details')->name('details')->to('test#details');
    $test_r->get('/module_components')->name('module_components')->to('test#module_components');
    $test_r->get('/status')->name('status')->to('running#status');
    $test_r->get('/livelog')->name('livelog')->to('running#livelog');
    $test_r->get('/liveterminal')->name('liveterminal')->to('running#liveterminal');
    $test_r->get('/streaming')->name('streaming')->to('running#streaming');
    $test_r->get('/edit')->name('edit_test')->to('running#edit');

    $test_r->get('/images/#filename')->name('test_img')->to('file#test_file');
    $test_r->get('/images/thumb/#filename')->name('test_thumbnail')->to('file#test_thumbnail');
    $test_r->get('/file/#filename')->name('test_file')->to('file#test_file');
    $test_r->get('/video' => sub { shift->render('test/video') })->name('video');
    # adding assetid => qr/\d+/ doesn't work here. wtf?
    $test_r->get('/asset/#assetid')->name('test_asset_id')->to('file#test_asset');
    $test_r->get('/asset/#assettype/#assetname')->name('test_asset_name')->to('file#test_asset');
    $test_r->get('/asset/#assettype/#assetname/*subpath')->name('test_asset_name_path')->to('file#test_asset');

    my $developer_auth = $test_r->under('/developer')->to('session#ensure_admin');
    my $developer_r    = $developer_auth->route('/')->to(namespace => 'OpenQA::WebAPI::Controller');
    $developer_r->get('/ws-console')->name('developer_ws_console')->to('developer#ws_console');

    my $step_r    = $test_r->route('/modules/:moduleid/steps/<stepid:step>')->to(controller => 'step');
    my $step_auth = $test_auth->route('/modules/:moduleid/steps/<stepid:step>');
    $step_r->get('/view')->to(action => 'view');
    $step_r->get('/edit')->name('edit_step')->to(action => 'edit');
    $step_r->get('/src')->name('src_step')->to(action => 'src');
    $step_auth->post('/')->name('save_needle_ajax')->to('step#save_needle_ajax');
    $step_r->get('/')->name('step')->to(action => 'view');

    $r->get('/needles/:needle_id/image')->name('needle_image_by_id')->to('file#needle_image_by_id');
    $r->get('/needles/:needle_id/json')->name('needle_json_by_id')->to('file#needle_json_by_id');
    $r->get('/needles/:distri/#name')->name('needle_file')->to('file#needle');
    # this route is used in the helper
    $r->get('/image/:md5_dirname/.thumbs/#md5_basename')->name('thumb_image')->to('file#thumb_image');
    # but this route is actually matched (in case apache is not catching this earlier)
    # due to the split md5_dirname having a /
    $r->get('/image/:md5_1/:md5_2/.thumbs/#md5_basename')->to('file#thumb_image');

    $r->get('/group_overview/<groupid:num>')->name('group_overview')->to('main#job_group_overview');
    $r->get('/parent_group_overview/<groupid:num>')->name('parent_group_overview')->to('main#parent_group_overview');

    # Favicon
    $r->get('/favicon.ico' => sub { my $c = shift; $c->render_static('favicon.ico') });
    $r->get('/index'       => sub { shift->render('main/index') });
    $r->get('/dashboard_build_results')->name('dashboard_build_results')->to('main#dashboard_build_results');
    $r->get('/api_help' => sub { shift->render('admin/api_help') })->name('api_help');

    # Default route
    $r->get('/' => sub { shift->render('main/index') })->name('index');
    $r->get('/changelog')->name('changelog')->to('main#changelog');

    # shorter version of route to individual job results
    $r->get('/t<testid:num>' => sub { shift->redirect_to('test') });

    # Redirection for old links to openQAv1
    $r->get(
        '/results' => sub {
            my $c = shift;
            $c->redirect_to('tests');
        });

    #
    ## Admin area starts here
    ###
    my %api_description;
    my $admin_r     = $admin_auth->route('/')->to(namespace => 'OpenQA::WebAPI::Controller::Admin');
    my $op_r        = $op_auth->route('/')->to(namespace => 'OpenQA::WebAPI::Controller::Admin');
    my $pub_admin_r = $r->route('/admin')->to(namespace => 'OpenQA::WebAPI::Controller::Admin');

    # operators accessible tables
    $pub_admin_r->get('/products')->name('admin_products')->to('product#index');
    $pub_admin_r->get('/machines')->name('admin_machines')->to('machine#index');
    $pub_admin_r->get('/test_suites')->name('admin_test_suites')->to('test_suite#index');

    $pub_admin_r->get('/job_templates/<groupid:num>')->name('admin_job_templates')->to('job_template#index');

    $pub_admin_r->get('/groups')->name('admin_groups')->to('job_group#index');
    $pub_admin_r->get('/job_group/<groupid:num>')->name('admin_job_group_row')->to('job_group#job_group_row');
    $pub_admin_r->get('/parent_group/<groupid:num>')->name('admin_parent_group_row')->to('job_group#parent_group_row');
    $pub_admin_r->get('/edit_parent_group/<groupid:num>')->name('admin_edit_parent_group')
      ->to('job_group#edit_parent_group');
    $pub_admin_r->get('/groups/connect/<groupid:num>')->name('job_group_new_media')->to('job_group#connect');

    $pub_admin_r->get('/assets')->name('admin_assets')->to('asset#index');
    $pub_admin_r->get('/assets/status')->name('admin_asset_status_json')->to('asset#status_json');

    $pub_admin_r->get('/workers')->name('admin_workers')->to('workers#index');
    $pub_admin_r->get('/workers/<worker_id:num>')->name('admin_worker_show')->to('workers#show');
    $pub_admin_r->get('/workers/<worker_id:num>/ajax')->name('admin_worker_previous_jobs_ajax')
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
    $admin_r->post('/groups/connect/<groupid:num>')->name('job_group_save_media')->to('job_group#save_connect');

    # Workers list as default option
    $op_r->get('/')->name('admin')->to('workers#index');

    $pub_admin_r->get('/influxdb/jobs')->to('influxdb#jobs');
    $pub_admin_r->get('/influxdb/minion')->to('influxdb#minion');

    ###
    ## Admin area ends here
    #

    #
    ## JSON API starts here
    ###
    # Array to store new API routes' references, so they can all be checked to get API description from POD
    my @api_routes   = ();
    my $api_ru       = $api_auth_any_user->route('/')->to(namespace => 'OpenQA::WebAPI::Controller::API::V1');
    my $api_ro       = $api_auth_operator->route('/')->to(namespace => 'OpenQA::WebAPI::Controller::API::V1');
    my $api_ra       = $api_auth_admin->route('/')->to(namespace => 'OpenQA::WebAPI::Controller::API::V1');
    my $api_public_r = $api_public->route('/')->to(namespace => 'OpenQA::WebAPI::Controller::API::V1');
    push @api_routes, $api_ru, $api_ro, $api_ra, $api_public_r;
    # this is fallback redirect if one does not use apache
    $api_public_r->websocket(
        '/ws/<workerid:num>' => sub {
            my $c        = shift;
            my $workerid = $c->param('workerid');
            # use port one higher than WebAPI
            my $port = 9527;
            if (my $custom = $c->req->url->to_abs->port) {
                $port = $custom + 1;
            }
            $c->redirect_to("http://localhost:$port/ws/$workerid");
        });
    my $api_job_auth = $r->under('/api/v1')->to(controller => 'API::V1', action => 'auth_jobtoken');
    my $api_r_job    = $api_job_auth->route('/')->to(namespace => 'OpenQA::WebAPI::Controller::API::V1');
    push @api_routes, $api_job_auth, $api_r_job;
    $api_r_job->get('/whoami')->name('apiv1_jobauth_whoami')->to('job#whoami');    # primarily for tests

    # api/v1/job_groups
    $api_public_r->get('/job_groups')->name('apiv1_list_job_groups')->to('job_group#list');
    $api_public_r->get('/job_groups/<group_id:num>')->name('apiv1_get_job_group')->to('job_group#list');
    $api_public_r->get('/job_groups/<group_id:num>/jobs')->name('apiv1_get_job_group_jobs')->to('job_group#list_jobs');
    $api_ra->post('/job_groups')->name('apiv1_post_job_group')->to('job_group#create');
    $api_ra->put('/job_groups/<group_id:num>')->name('apiv1_put_job_group')->to('job_group#update');
    $api_ra->delete('/job_groups/<group_id:num>')->name('apiv1_delete_job_group')->to('job_group#delete');

    # api/v1/parent_groups
    $api_public_r->get('/parent_groups')->name('apiv1_list_parent_groups')->to('job_group#list');
    $api_public_r->get('/parent_groups/<group_id:num>')->name('apiv1_get_parent_group')->to('job_group#list');
    $api_ra->post('/parent_groups')->name('apiv1_post_parent_group')->to('job_group#create');
    $api_ra->put('/parent_groups/<group_id:num>')->name('apiv1_put_parent_group')->to('job_group#update');
    $api_ra->delete('/parent_groups/<group_id:num>')->name('apiv1_delete_parent_group')->to('job_group#delete');

    # api/v1/jobs
    $api_public_r->get('/jobs')->name('apiv1_jobs')->to('job#list');
    $api_public_r->get('/jobs/overview')->name('apiv1_jobs_overview')->to('job#overview');
    $api_ro->post('/jobs')->name('apiv1_create_job')->to('job#create');
    $api_ro->post('/jobs/cancel')->name('apiv1_cancel_jobs')->to('job#cancel');
    $api_ro->post('/jobs/restart')->name('apiv1_restart_jobs')->to('job#restart');

    my $job_r = $api_ro->route('/jobs/<jobid:num>');
    push @api_routes, $job_r;
    $api_public_r->route('/jobs/<jobid:num>')->name('apiv1_job')->to('job#show');
    $api_public_r->route('/jobs/<jobid:num>/details')->name('apiv1_job')->to('job#show', details => 1);
    $job_r->put('/')->name('apiv1_put_job')->to('job#update');
    $job_r->delete('/')->name('apiv1_delete_job')->to('job#destroy');
    $job_r->post('/prio')->name('apiv1_job_prio')->to('job#prio');
    $job_r->post('/set_done')->name('apiv1_set_done')->to('job#done');
    $job_r->post('/status')->name('apiv1_update_status')->to('job#update_status');
    $job_r->post('/artefact')->name('apiv1_create_artefact')->to('job#create_artefact');
    $job_r->post('/upload_state')->to('job#upload_state');

    $job_r->post('/restart')->name('apiv1_restart')->to('job#restart');
    $job_r->post('/cancel')->name('apiv1_cancel')->to('job#cancel');
    $job_r->post('/duplicate')->name('apiv1_duplicate')->to('job#duplicate');

    # api/v1/bugs
    $api_public_r->get('/bugs')->name('apiv1_bugs')->to('bug#list');
    $api_ro->post('/bugs')->name('apiv1_create_bug')->to('bug#create');
    my $bug_r = $api_ro->route('/bugs/<id:num>');
    push @api_routes, $bug_r;
    $bug_r->get('/')->name('apiv1_show_bug')->to('bug#show');
    $bug_r->put('/')->name('apiv1_put_bug')->to('bug#update');
    $bug_r->delete('/')->name('apiv1_delete_bug')->to('bug#destroy');

    # api/v1/workers
    $api_public_r->get('/workers')->name('apiv1_workers')->to('worker#list');
    $api_description{'apiv1_worker'}
      = 'Each entry contains the "hostname", the boolean flag "connected" which can be 0 or 1 depending on the connection to the websockets server and the field "status" which can be "dead", "idle", "running". A worker can be considered "up" when "connected=1" and "status!=dead"';
    $api_ro->post('/workers')->name('apiv1_create_worker')->to('worker#create');
    my $worker_r = $api_ro->route('/workers/<workerid:num>');
    push @api_routes, $worker_r;
    $api_public_r->route('/workers/<workerid:num>')->get('/')->name('apiv1_worker')->to('worker#show');
    $worker_r->post('/commands/')->name('apiv1_create_command')->to('command#create');
    $api_ro->delete('/workers/<worker_id:num>')->name('apiv1_worker_delete')->to('worker#delete');

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
    $api_r_job->post('/barrier/<name:barrier>')->name('apiv1_barrier_wait')->to('locks#barrier_wait');
    $api_r_job->delete('/barrier/<name:barrier>')->name('apiv1_barrier_destroy')->to('locks#barrier_destroy');

    # api/v1/mm
    my $mm_api = $api_r_job->route('/mm');
    push @api_routes, $mm_api;
    $mm_api->get('/children/:status' => [status => [qw(running scheduled done)]])->name('apiv1_mm_running_children')
      ->to('mm#get_children_status');
    $mm_api->get('/children')->name('apiv1_mm_children')->to('mm#get_children');
    $mm_api->get('/parents')->name('apiv1_mm_parents')->to('mm#get_parents');

    # api/v1/isos
    $api_ro->get('/isos/<scheduled_product_id:num>')->name('apiv1_show_scheduled_product')
      ->to('iso#show_scheduled_product');
    $api_ro->post('/isos')->name('apiv1_create_iso')->to('iso#create');
    $api_ra->delete('/isos/#name')->name('apiv1_destroy_iso')->to('iso#destroy');
    $api_ro->post('/isos/#name/cancel')->name('apiv1_cancel_iso')->to('iso#cancel');

    # api/v1/assets
    $api_ro->post('/assets')->name('apiv1_post_asset')->to('asset#register');
    $api_public_r->get('/assets')->name('apiv1_get_asset')->to('asset#list');
    $api_ra->post('/assets/cleanup')->name('apiv1_trigger_asset_cleanup')->to('asset#trigger_cleanup');
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

    # api/v1/job_templates_scheduling
    $api_public_r->get('job_templates_scheduling/<id:num>')->name('apiv1_job_templates_schedules')
      ->to('job_template#schedules', id => undef);
    $api_public_r->get('job_templates_scheduling/<name:str>')->to('job_template#schedules', name => undef);
    $api_ra->post('job_templates_scheduling/<id:num>')->to('job_template#update', id => undef);
    # Deprecated experimental aliases for the above routes
    $api_public_r->get('experimental/job_templates_scheduling/<id:num>')->name('apiv1_job_templates_schedules')
      ->to('job_template#schedules', id => undef);
    $api_public_r->get('experimental/job_templates_scheduling/<name:str>')->to('job_template#schedules', name => undef);
    $api_ra->post('experimental/job_templates_scheduling/<id:num>')->to('job_template#update', id => undef);

    # api/v1/comments
    $api_public_r->get('/jobs/<job_id:num>/comments')->name('apiv1_list_comments')->to('comment#list');
    $api_public_r->get('/jobs/<job_id:num>/comments/<comment_id:num>')->name('apiv1_get_comment')->to('comment#text');
    $api_ru->post('/jobs/<job_id:num>/comments')->name('apiv1_post_comment')->to('comment#create');
    $api_ru->put('/jobs/<job_id:num>/comments/<comment_id:num>')->name('apiv1_put_comment')->to('comment#update');
    $api_ra->delete('/jobs/<job_id:num>/comments/<comment_id:num>')->name('apiv1_delete_comment')->to('comment#delete');
    $api_public_r->get('/groups/<group_id:num>/comments')->name('apiv1_list_group_comment')->to('comment#list');
    $api_public_r->get('/groups/<group_id:num>/comments/<comment_id:num>')->name('apiv1_get_group_comment')
      ->to('comment#text');
    $api_ru->post('/groups/<group_id:num>/comments')->name('apiv1_post_group_comment')->to('comment#create');
    $api_ru->put('/groups/<group_id:num>/comments/<comment_id:num>')->name('apiv1_put_group_comment')
      ->to('comment#update');
    $api_ra->delete('/groups/<group_id:num>/comments/<comment_id:num>')->name('apiv1_delete_group_comment')
      ->to('comment#delete');
    $api_public_r->get('/parent_groups/<parent_group_id:num>/comments')->name('apiv1_list_parent_group_comment')
      ->to('comment#list');
    $api_public_r->get('/parent_groups/<parent_group_id:num>/comments/<comment_id:num>')
      ->name('apiv1_get_parent_group_comment')->to('comment#text');
    $api_ru->post('/parent_groups/<parent_group_id:num>/comments')->name('apiv1_post_parent_group_comment')
      ->to('comment#create');
    $api_ru->put('/parent_groups/<parent_group_id:num>/comments/<comment_id:num>')
      ->name('apiv1_put_parent_group_comment')->to('comment#update');
    $api_ra->delete('/parent_groups/<parent_group_id:num>/comments/<comment_id:num>')
      ->name('apiv1_delete_parent_group_comment')->to('comment#delete');

    # json-rpc methods not migrated to this api: echo, list_commands
    ###
    ## JSON API ends here
    #

    # api/v1/feature
    $api_ru->post('/feature')->name('apiv1_post_informed_about')->to('feature#informed');

    # Parse API controller modules for POD
    get_pod_from_controllers(@api_routes);
    # Set API descriptions
    $api_description{apiv1} = 'Root API V1 path';
    foreach my $api_rt (@api_routes) {
        set_api_desc(\%api_description, $api_rt);
    }

    OpenQA::Setup::setup_validator_check_for_datetime($self);

    $self->plugin('OpenQA::WebAPI::Plugin::MemoryLimit');

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

sub schema { OpenQA::Schema->singleton }

sub run { __PACKAGE__->new->start }

1;
