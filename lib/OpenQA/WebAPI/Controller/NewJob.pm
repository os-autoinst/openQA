# Copyright 2014-2021 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::WebAPI::Controller::NewJob;
use Mojo::Base 'Mojolicious::Controller', -signatures;

#use Cwd 'realpath';
#use Encode 'decode_utf8';
#use Mojo::File 'path';
#use Mojo::URL;
#use Mojo::Util 'decode';
# use OpenQA::Utils qw(ensure_timestamp_appended find_bug_number locate_needle needledir testcasedir);
# use OpenQA::Jobs::Constants;
# use File::Basename;
# use File::Which 'which';
# use POSIX 'strftime';
# use Mojo::JSON 'decode_json';

sub create ($self) {
    #my $self = shift;
    warn "route called";
    #$self->stash(msg => "Trigger job");
    $self->render(template => "NewJob/create", msg => "Trigger job");
    # openqa-cli schedule \
            # --monitor \
            # --host "${OPENQA_HOST:-https://openqa.opensuse.org}/" \
            # --apikey "$OPENQA_API_KEY" --apisecret "$OPENQA_API_SECRET" \
            # --param-file SCENARIO_DEFINITIONS_YAML=scenario-definitions.yaml \
            # DISTRI=example VERSION=0 FLAVOR=DVD ARCH=x86_64 TEST=simple_boot \
            # BUILD="$GH_REPO.git#$GH_REF" _GROUP_ID="0" \
            # CASEDIR="$GITHUB_SERVER_URL/$GH_REPO.git#$GH_REF" \
            # NEEDLES_DIR="%%CASEDIR%%/needles"
}


1;
