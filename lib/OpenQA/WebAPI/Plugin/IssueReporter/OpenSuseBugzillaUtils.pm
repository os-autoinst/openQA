# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::WebAPI::Plugin::IssueReporter::OpenSuseBugzillaUtils;
use Mojo::Base -strict, -signatures;
use Exporter qw(import);

our @EXPORT_OK = qw(get_bugzilla_url get_bugzilla_distri_name get_bugzilla_product_name);

# below constants are taken directly from the external_reporting.html.ep
# ideally this should be in a config file to make openQA product/brand-agnostic
use constant DISTRI_TO_PRODUCT_URL => {
    sle => 'https://bugzilla.suse.com/enter_bug.cgi',
    'sle-micro' => 'https://bugzilla.suse.com/enter_bug.cgi',
    opensuse => 'https://bugzilla.opensuse.org/enter_bug.cgi',
    caasp => 'https://bugzilla.suse.com/enter_bug.cgi',
    openqa => 'https://progress.opensuse.org/projects/openqav3/issues/new',
    kubic => 'https://bugzilla.opensuse.org/enter_bug.cgi',
    microos => 'https://bugzilla.opensuse.org/enter_bug.cgi',
    alp => 'https://bugzilla.suse.com/enter_bug.cgi',
};

use constant DISTRI_TO_PROD => {
    sle => 'SUSE Linux Enterprise',
    'sle-micro' => 'SUSE Linux',
    opensuse => 'openSUSE',
    caasp => 'SUSE CaaS Platform',
    kubic => 'openSUSE',
    microos => 'openSUSE',
    alp => 'ALP',
};

use constant FLAVOR_TO_PROD_SLE => {
    Server => 'Server',
    'Server-Incidents' => 'Server',
    'Server-Updates' => 'Server',
    'Server-HA' => 'High Availability Extension',
    'Server-RT' => 'Real Time Extension',
    Desktop => 'Desktop',
    'Desktop-Incidents' => 'Desktop',
    'Desktop-Updates' => 'Desktop',
    SAP => 'for SAP Applications',
    Leanos => 'Server',
    Installer => 'Server',
};

use constant PUBLIC_SLE_PRODUCTS => {
    Server => 'Server',
    Desktop => 'Desktop',
    'High Availability Extension' => 'High Availability',    # the public version leaves out the "Extension" suffix
};

sub get_bugzilla_url ($raw_distri) {
    return DISTRI_TO_PRODUCT_URL->{$raw_distri} // DISTRI_TO_PRODUCT_URL->{sle};
}

sub get_bugzilla_distri_name ($raw_distri) {
    return DISTRI_TO_PROD->{$raw_distri} // 'UNKNOWN DISTRI';
}

# taken from the external_reporting.html.ep
# likely this could be improved
sub get_bugzilla_product_name ($job, $raw_distri, $distri_ref) {
    return _sle_product($job, $distri_ref) if $raw_distri eq 'sle';
    return _sle_micro_product($job) if $raw_distri eq 'sle-micro';
    return _opensuse_product($job) if $raw_distri eq 'opensuse' || $raw_distri eq 'microos';
    return _caasp_product($job) if $raw_distri eq 'caasp';
    return 'openQA' if $raw_distri eq 'openqa';
    return '';
}

sub _sle_product ($job, $distri_ref) {
    my $subproduct = $job->FLAVOR // '';
    $subproduct =~ s/(\w*)(-\w*)?/$1/;

    return '' unless $subproduct;

    my $version = $job->VERSION // '';
    $version =~ s/-/ /g;

    $version = '12 (SLES 12)' if $subproduct eq 'Server' && $version eq '12';

    my $sle_product = FLAVOR_TO_PROD_SLE->{$subproduct} // 'Server';

    if (my $public = PUBLIC_SLE_PRODUCTS->{$sle_product}) {
        if ($version =~ /(\d+)\s+SP(\d+)/ && $1 == 15 && $2 >= 3) {
            $$distri_ref = "PUBLIC $$distri_ref";
            $sle_product = $public;
        }
    }
    return "$sle_product $version";
}

sub _sle_micro_product ($job) {
    my $version = $job->VERSION // '';
    my $product = "Micro $version";
    return ($version eq '6.1' || $version eq '6.2') ? $product : "Enterprise $product";
}

sub _opensuse_product ($job) {
    return ($job->VERSION // '') eq 'Tumbleweed'
      ? 'Tumbleweed'
      : 'Distribution';
}

sub _caasp_product ($job) {
    (my $version = $job->VERSION // '') =~ s/\.[0-9]//;
    return $version;
}

1;
