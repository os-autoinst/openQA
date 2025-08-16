# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::VcsHook;

use Mojo::Base -base, -signatures;
use Mojo::JSON qw(encode_json);
use Mojo::URL;

sub process_payload ($self, $type, $json) {
    my $pr = $json->{pull_request} // {};
    my %vars;
    my $head = $pr->{head} // {};
    my $repo = $head->{repo} // {};
    my @missing;
    push @missing, 'pull_request/id' unless $vars{pr_id} = $pr->{id};
    push @missing, 'pull_request/head/sha' unless $vars{sha} = $head->{sha};
    push @missing, 'pull_request/head/repo/full_name' unless $vars{repo_name} = $repo->{full_name};
    push @missing, 'pull_request/head/repo/clone_url' unless $vars{clone_url} = $repo->{clone_url};
    my $requested_reviewer;
    my $repo_html_url;
    my $repo_api_url;
    if ($type eq 'github') {
        push @missing, 'pull_request/statuses_url' unless $vars{statuses_url} = $pr->{statuses_url};
    }
    else {
        # https://src.suse.de/api/v1/repos/owner/reponame/statuses/sha
        push @missing, 'repository/url' unless $repo_api_url = $json->{repository}->{url};
        push @missing, 'repository/html_url' unless $repo_html_url = $json->{repository}->{html_url};
        push @missing, 'requested_reviewer/username'
          unless $requested_reviewer = $json->{requested_reviewer}->{username};
    }

    die {status => 400, text => 'missing fields: ' . join(', ', @missing)} if @missing;
    if ($type eq 'github') {
        $vars{raw_url} = "https://raw.githubusercontent.com/$vars{repo_name}/$vars{sha}";
    }
    else {
        $vars{statuses_url} = "$repo_api_url/statuses/$vars{sha}";
        my $review_user = 'qam-openqa';    # TODO configure
        unless ($requested_reviewer eq $review_user) {
            die {status => 200, json => {message => "Nothing to do for reviewer $requested_reviewer"}};
        }
        $vars{raw_url} = "$repo_html_url/raw/branch/$vars{sha}";
    }
    $vars{html_url} = $pr->{html_url};
    return \%vars;
}

sub process_query_params ($self, $params) {
    # compute parameters
    my %up_params = map { uc $_ => $params->{$_} } keys %$params;
    my %params = map { $_ => $up_params{$_} =~ s@%2F@/@gr } keys %up_params;
    return \%params;
}

sub schedule_product_params ($self, $vars, $params, $base_url) {
    # set some useful defaults
    $params->{BUILD} //= "$vars->{repo_name}#$vars->{sha}";
    $params->{CASEDIR} //= "$vars->{clone_url}#$vars->{sha}";
    $params->{_GROUP_ID} //= '0';
    $params->{PRIO} //= '100';
    $params->{NEEDLES_DIR} //= '%%CASEDIR%%/needles';

    # set the URL for the scenario definitions YAML file so the Minion job will download it from GitHub
    my $relative_file_path = $params->{SCENARIO_DEFINITIONS_YAML_FILE} // 'scenario-definitions.yaml';
    $params->{SCENARIO_DEFINITIONS_YAML_FILE} = "$vars->{raw_url}/$relative_file_path";

    # add "target URL" for the "Details" button of the CI status
    #    my $base_url = $self->app->config->{global}->{base_url} // $self->req->url->base;
    $params->{CI_TARGET_URL} = $base_url if $base_url;

    # set GitHub parameters so the Minion job will be able to report the status back to GitHub
    $params->{GITHUB_REPO} = $vars->{repo_name};
    $params->{GITHUB_SHA} = $vars->{sha};
    $params->{GITHUB_STATUSES_URL} = $vars->{statuses_url};
    $params->{GITHUB_PR_URL} = $vars->{html_url} if $vars->{html_url};
}

package OpenQA::VcsHook::Github;
use Mojo::Base 'OpenQA::VcsHook', -signatures;

package OpenQA::VcsHook::Gitea;
use Mojo::Base 'OpenQA::VcsHook', -signatures;

1;
