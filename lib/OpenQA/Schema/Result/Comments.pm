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
use base 'DBIx::Class::Core';
use OpenQA::Utils qw(find_bugref find_bugrefs);
use strict;

__PACKAGE__->load_components(qw(Core));
__PACKAGE__->load_components(qw(InflateColumn::DateTime Timestamps));
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
    flags => {
        data_type     => 'integer',
        is_nullable   => 1,
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


=head2 bugref

Returns the first bugref if C<$self> contains a bugref, e.g. 'bug#1234'.
=cut
sub bugref {
    my ($self) = @_;
    return find_bugref($self->text);
}

=head2 bugrefs

Returns all bugrefs in C<$self>, e.g. 'bug#1234 poo#1234'.
=cut
sub bugrefs {
    my ($self) = @_;
    return find_bugrefs($self->text);
}

=head2 label

Returns label value if C<$self> is label, e.g. 'label:my_label' returns 'my_label'
=cut
sub label {
    my ($self) = @_;
    $self->text =~ /\blabel:(\w+)\b/;
    return $1;
}

=head2 tag

Parses a comment and checks for a C<tag> mark. A tag is written as
C<tag:<build_nr>:<type>[:<description>]>. A tag is only accepted on group
comments not on test comments. The description is optional.

Returns C<build_nr>, C<type> and optionally C<description> if C<$self> is tag,
e.g. 'tag:0123:important:GM' returns a list of '0123', 'important' and 'GM'.
=cut
sub tag {
    my ($self) = @_;
    $self->text =~ /\btag:(?<build>([-.\d\w]+-)?[@\d]+):(?<type>[-\w]+)(:(?<description>\w+))?\b/;
    return $+{build}, $+{type}, $+{description};
}

sub rendered_markdown {
    my ($self) = @_;

    my $m = CommentsMarkdownParser->new;
    return Mojo::ByteStream->new($m->markdown($self->text));
}

sub hash {
    my ($self) = @_;
    return {
        user    => $self->user->name,
        text    => $self->text,
        created => $self->t_created->datetime() . 'Z',
        updated => $self->t_updated->datetime() . 'Z',
    };
}

sub extended_hash {
    my ($self) = @_;
    return {
        text             => $self->text,
        renderedMarkdown => $self->rendered_markdown,
        bugrefs          => $self->bugrefs,
        created          => $self->t_created->strftime("%Y-%m-%d %H:%M:%S %z"),
        updated          => $self->t_updated->strftime("%Y-%m-%d %H:%M:%S %z"),
        userName         => $self->user->name
    };
}

package CommentsMarkdownParser;
require Text::Markdown;
our @ISA = qw(Text::Markdown);
use Regexp::Common 'URI';
use OpenQA::Utils 'bugref_to_href';

sub _DoAutoLinks {
    my ($self, $text) = @_;

    # auto-replace bugrefs with 'a href...'
    $text = bugref_to_href($text);

    # auto-replace every http(s) reference which is not already either html
    # 'a href...' or markdown link '[link](url)' or enclosed by Text::Markdown
    # URL markers '<>'
    $text =~ s@(?<!['"(<>])($RE{URI})@<$1>@gi;

    # For tests make sure that references into test modules and needling steps also work
    $text =~ s{\b(t#([\w/]+))}{<a href="/tests/$2">$1</a>}gi;

    $text =~ s{(http://\S*\.gif$)}{<img src="$1"/>}gi;
    $self->SUPER::_DoAutoLinks($text);
}

1;
