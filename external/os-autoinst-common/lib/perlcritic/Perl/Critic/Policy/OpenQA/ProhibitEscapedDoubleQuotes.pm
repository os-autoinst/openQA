# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package Perl::Critic::Policy::OpenQA::ProhibitEscapedDoubleQuotes;

use strict;
use warnings;
use experimental 'signatures';
use base 'Perl::Critic::Policy';

use Perl::Critic::Utils qw( :severities );

our $VERSION = '0.0.1';

my $DESC = q{Nested escaped double quotes in double-quoted string};
my $EXPL = q{Use qq{...} or other delimiters to avoid backslash-escaping double quotes inside strings};

sub default_severity { return $SEVERITY_MEDIUM }
sub default_themes { return qw(openqa) }
sub applies_to { return qw(PPI::Token::Quote::Double) }

# Existing files with violations to be ignored to keep the build green while
# preventing any further/new violations from being introduced in other files.
my %ignored_files = map { $_ => 1 } qw(
    lib/OpenQA/Downloader.pm
    lib/OpenQA/Markdown.pm
    lib/OpenQA/LiveHandler/Controller/LiveViewHandler.pm
    lib/OpenQA/Schema.pm
    lib/OpenQA/Shared/Controller/Running.pm
    lib/OpenQA/Task/Needle/Delete.pm
    lib/OpenQA/Shared/Controller/Auth.pm
    lib/OpenQA/WebSockets.pm
    lib/OpenQA/Worker.pm
    lib/OpenQA/WebAPI/Controller/Test.pm
    t/10-tests_overview.t
    t/25-bugs.t
    t/10-jobs.t
    t/33-developer_mode.t
    t/34-developer_mode-unit.t
    t/40-script_load_dump_templates.t
    t/44-scripts-initdb.t
    t/35-script_clone_job.t
    t/43-cli-api.t
    t/api/09-comments.t
    t/lib/OpenQA/Test/Database.pm
    t/full-stack.t
    t/ui/16-activity-view.t
    t/ui/15-comments.t
    t/ui/12-needle-edit.t
    t/ui/16-tests_job_next_previous.t
    t/ui/13-admin.t
    t/ui/10-tests_overview.t
    tools/generate-cli-completions
    t/ui/25-developer_mode.t
    t/ui/18-tests-details.t
);

sub violates ($self, $elem, $doc) {
    my $filename = $doc->filename();
    if ($filename) {
        for my $ignored (keys %ignored_files) {
            if ($filename =~ /\Q$ignored\E$/) {
                return ();
            }
        }
    }

    my $content = $elem->content;

    # Strip the enclosing double quotes of PPI::Token::Quote::Double
    my $inner = $content;
    if ($inner =~ s/^"// && $inner =~ s/"$//) {
        # Match a double quote preceded by an odd number of backslashes
        if ($inner =~ /(?<!\\)(?:\\\\)*\\"/ ) {
            return $self->violation($DESC, $EXPL, $elem);
        }
    }

    return ();
}

1;
