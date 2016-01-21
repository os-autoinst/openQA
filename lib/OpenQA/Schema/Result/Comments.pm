# Copyright (C) 2015 SUSE Linux Products GmbH
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

package OpenQA::Schema::Result::Comments;
use base qw/DBIx::Class::Core/;
use strict;

__PACKAGE__->load_components(qw/Core/);
__PACKAGE__->load_components(qw/InflateColumn::DateTime Timestamps/);
__PACKAGE__->table('comments');
__PACKAGE__->add_columns(
    id => {
        data_type         => 'integer',
        is_auto_increment => 1,
    },
    job_id => {
        data_type      => 'integer',
        is_foreign_key => 1,
        is_nullable    => 1,
    },
    group_id => {
        data_type      => 'integer',
        is_foreign_key => 1,
        is_nullable    => 1,
    },
    text => {
        data_type => 'text'
    },
    user_id => {
        data_type      => 'integer',
        is_foreign_key => 1,
    },
    hidden => {
        data_type     => 'boolean',
        default_value => '0',
    },
);

__PACKAGE__->add_timestamps;
__PACKAGE__->set_primary_key('id');
__PACKAGE__->belongs_to(user => 'OpenQA::Schema::Result::Users', 'user_id');

__PACKAGE__->belongs_to(
    "group",
    "OpenQA::Schema::Result::JobGroups",
    {'foreign.id' => "self.group_id"},
    {
        is_deferrable => 1,
        join_type     => "LEFT",
        on_delete     => "CASCADE",
        on_update     => "CASCADE",
    },
);

__PACKAGE__->belongs_to(
    "job",
    "OpenQA::Schema::Result::Jobs",
    {'foreign.id' => "self.job_id"},
    {
        is_deferrable => 1,
        join_type     => "LEFT",
        on_delete     => "CASCADE",
        on_update     => "CASCADE",
    },
);

sub rendered_markdown {
    my ($self) = @_;

    my $m = CommentsMarkdownParser->new;
    Mojo::ByteStream->new($m->markdown($self->text));
}

package CommentsMarkdownParser;
require Text::Markdown;
our @ISA = qw/Text::Markdown/;
use Regexp::Common qw/URI/;

sub _DoAutoLinks {
    my ($self, $text) = @_;

    # auto-replace every http(s) reference which is not already either html
    # 'a href...' or markdown link '[link](url)' or enclosed by Text::Markdown
    # URL markers '<>'
    $text =~ s@(?<!['"(<>])($RE{URI})@<$1>@gi;

    $text =~ s{(bnc#(\d+))}{<a href="https://bugzilla.novell.com/show_bug.cgi?id=$2">$1</a>}gi;
    $text =~ s{(bsc#(\d+))}{<a href="https://bugzilla.suse.com/show_bug.cgi?id=$2">$1</a>}gi;
    $text =~ s{(boo#(\d+))}{<a href="https://bugzilla.opensuse.org/show_bug.cgi?id=$2">$1</a>}gi;
    $text =~ s{(poo#(\d+))}{<a href="https://progress.opensuse.org/issues/$2">$1</a>}gi;
    $text =~ s{(t#(\d+))}{<a href="/tests/$2">$1</a>}gi;

    $text =~ s{(http://\S*\.gif$)}{<img src="$1"/>}gi;
    $self->SUPER::_DoAutoLinks($text);
}

1;
