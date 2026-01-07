# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::WebAPI::Plugin::IssueReporter::OpenSuseKernelBug;
use Mojo::Base -strict, -signatures;
use Mojo::Template;
use Mojo::Loader qw(data_section);
use Mojo::URL;
use OpenQA::WebAPI::Plugin::IssueReporter::Context qw(get_context);
use OpenQA::WebAPI::Plugin::IssueReporter::OpenSuseBugzillaUtils
  qw(get_bugzilla_url get_bugzilla_distri_name get_bugzilla_product_name);

sub actions ($c) {
    my $ctx = get_context($c) or return [];
    my $job = $ctx->{job};
    my $raw_distri = $job->DISTRI // '';
    my $bugzilla_distri = get_bugzilla_distri_name($raw_distri);
    my $bugzilla_product = get_bugzilla_product_name($job, $raw_distri, \$bugzilla_distri);
    my $bugzilla_url = get_bugzilla_url($raw_distri);

    # main part of the kernel bug report
    my $kernel_bug = _render(
        'kernel_bug.txt.ep',
        {
            build => $ctx->{build},
            distri => $raw_distri,
            version => $ctx->{version},
        });

    my $url = Mojo::URL->new($bugzilla_url)->query(
        {
            short_desc => "[Build $ctx->{build}] Kernel test fails in $ctx->{module}",
            comment => $kernel_bug,
            product => "$bugzilla_distri $bugzilla_product",
        });

    return [
        {
            id => 'kernel_bugzilla',
            label => 'Report kernel product bug',
            icon => 'fa-microchip',
            url => "$url",
        }];
}

sub _render ($name, $vars) {
    my $tmpl = data_section(__PACKAGE__, $name);
    return Mojo::Template->new(vars => 1)->render($tmpl, $vars);
}

1;

__DATA__
@@ kernel_bug.txt.ep

== EDIT ==
IMPORTANT: For kernel bugs please provide detailed kernel information (`uname -a`, rpm -qi kernel-default, ...)

Build details:
Build: <%= $build %>
Distri: <%= $distri %>
Version: <%= $version %>
