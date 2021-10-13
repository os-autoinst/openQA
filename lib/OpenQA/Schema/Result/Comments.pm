# Copyright 2015 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Schema::Result::Comments;
use Mojo::Base 'DBIx::Class::Core', -signatures;

use OpenQA::Utils qw(find_bugref find_bugrefs);
use OpenQA::Markdown qw(markdown_to_html);

__PACKAGE__->load_components(qw(Core));
__PACKAGE__->load_components(qw(InflateColumn::DateTime Timestamps));
__PACKAGE__->table('comments');
__PACKAGE__->add_columns(
    id => {
        data_type => 'integer',
        is_auto_increment => 1,
    },
    job_id => {
        data_type => 'integer',
        is_foreign_key => 1,
        is_nullable => 1,
    },
    group_id => {
        data_type => 'integer',
        is_foreign_key => 1,
        is_nullable => 1,
    },
    parent_group_id => {
        data_type => 'integer',
        is_foreign_key => 1,
        is_nullable => 1,
    },
    text => {
        data_type => 'text'
    },
    user_id => {
        data_type => 'integer',
        is_foreign_key => 1,
    },
    flags => {
        data_type => 'integer',
        is_nullable => 1,
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
        join_type => "LEFT",
        on_delete => "CASCADE",
        on_update => "CASCADE",
    },
);

__PACKAGE__->belongs_to(
    "parent_group",
    "OpenQA::Schema::Result::JobGroupParents",
    {'foreign.id' => "self.parent_group_id"},
    {
        is_deferrable => 1,
        join_type => "LEFT",
        on_delete => "CASCADE",
        on_update => "CASCADE",
    },
);

__PACKAGE__->belongs_to(
    "job",
    "OpenQA::Schema::Result::Jobs",
    {'foreign.id' => "self.job_id"},
    {
        is_deferrable => 1,
        join_type => "LEFT",
        on_delete => "CASCADE",
        on_update => "CASCADE",
    },
);


=head2 bugref

Returns the first bugref if C<$self> contains a bugref, e.g. 'bug#1234'.
=cut
sub bugref ($self) { find_bugref($self->text) }

=head2 bugrefs

Returns all bugrefs in C<$self>, e.g. 'bug#1234 poo#1234'.
=cut
sub bugrefs ($self) { find_bugrefs($self->text) }

=head2 label

Returns label value if C<$self> is label, e.g. 'label:my_label' returns 'my_label'
=cut
sub label ($self) {
    $self->text =~ /\blabel:(\w+)\b/;
    return $1;
}

=head2 force_result

Returns new result value if C<$self> is a special "force_result" label, e.g.
'label:force_result:passed' returns 'passed'

=cut

sub force_result ($self) {
    $self->label && $self->text =~ /\blabel:force_result:(\w+):?(\w*)/;
    return ($1, $2);
}

=head2 tag

Parses a comment and checks for a C<tag> mark. A tag is written as
C<tag:<build_nr>:<type>[:<description>]>. A tag is only accepted on group
comments not on test comments. The description is optional.

Returns C<build_nr>, C<type> and optionally C<description> if C<$self> is tag,
e.g. 'tag:0123:important:GM' returns a list of '0123', 'important' and 'GM'.
=cut
sub tag ($self) {
    $self->text
      =~ /\btag:((?<version>[-.@\d\w]+)-)?(?<build>[-.@\d\w]+):(?<type>[-@\d\w]+)(:(?<description>[@\d\w]+))?\b/;
    return $+{build}, $+{type}, $+{description}, $+{version};
}

sub rendered_markdown ($self) { Mojo::ByteStream->new(markdown_to_html($self->text)) }

sub hash ($self) {
    return {
        user => $self->user->name,
        text => $self->text,
        created => $self->t_created->datetime() . 'Z',
        updated => $self->t_updated->datetime() . 'Z',
    };
}

sub extended_hash ($self) {
    return {
        id => $self->id,
        text => $self->text,
        renderedMarkdown => $self->rendered_markdown->to_string,
        bugrefs => $self->bugrefs,
        created => $self->t_created->strftime("%Y-%m-%d %H:%M:%S %z"),
        updated => $self->t_updated->strftime("%Y-%m-%d %H:%M:%S %z"),
        userName => $self->user->name
    };
}

1;
