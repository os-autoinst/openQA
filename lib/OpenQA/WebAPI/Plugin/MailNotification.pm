# Copyright (C) 2016 SUSE LLC
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

package OpenQA::WebAPI::Plugin::MailNotification;

use strict;
use warnings;

use parent qw/Mojolicious::Plugin/;
use Mojo::IOLoop;
use OpenQA::Schema::Result::JobGroupSubscriptions;

use Email::Sender::Simple qw(sendmail);
use Email::Simple;
use Email::Simple::Creator;
use Try::Tiny;

my $config;
my $from;
my $pretend;

sub register {
    my ($self, $app) = @_;
    my $reactor = Mojo::IOLoop->singleton;
    $config  = $app->config;
    $from    = $config->{mail_notification}{from};
    $pretend = $config->{mail_notification}{pretend};
    $reactor->on('openqa_user_new_comment' => sub { shift; $self->on_new_comment($app, @_) });
}

sub send_mail {
    my ($to, $subject, $message) = @_;

    my @header = (
        To      => $to,
        Subject => $subject
    );
    push(@header, From => $from) if $from;

    my $email = Email::Simple->create(
        header => \@header,
        body   => $message,
    );

    sendmail($email);
}

# table events
sub on_new_comment {
    my ($self, $app, $args) = @_;
    my ($user_id, $connection_id, $event, $event_data) = @$args;

    # no need to log openqa_ prefix in openqa log
    $event =~ s/^openqa_//;

    # find comment in database
    my $comment = $app->db->resultset('Comments')->find($event_data->{id});
    return unless $comment;

    my $message = $comment->user->name . " wrote:\n\n" . $comment->text;
    my $subject;
    my $path;

    # check context (eg. job group) of the comment
    my $user_ids;
    if ($comment->group_id) {
        $user_ids = $app->db->resultset('JobGroupSubscriptions')->search(
            {
                group_id => $comment->group_id,
                user_id  => {'!=' => $comment->user->id},
                flags    => OpenQA::Schema::Result::JobGroupSubscriptions::MAIL_ON_NEW_COMMENT
            })->get_column('user_id');
        # Note: don't know how to search using a bitmask in the database
        # No problem so far since currently only mail subscribtions for new comments are
        # supported, but it might be desirable to enable/disable other kinds of subscribtions

        my $group = $app->db->resultset('JobGroups')->find($comment->group_id);
        $subject = 'New comment in job group: ' . $group->name;
        $path    = '/group_overview/' . $group->id;
    }
    else {
        return;    # context not supported (eg. job comment)
    }

    # find subscribers
    my $subscribers = $app->db->resultset('Users')->search(
        {
            id => {-in => $user_ids->as_query}});

    # send mails to all subscribers
    $message = $message . "\n\n" . $config->{global}{base_url} . $path;
    while (my $subscriber = $subscribers->next) {
        if ($pretend) {
            $app->log->debug('Would have sent mail to: ' . $subscriber->email . '\n');
        }
        else {
            try {
                send_mail($subscriber->email, $subject, $message);
            }
            catch {
                $app->log->debug('Unable to send mail notification: ' . $_->message);
            };
        }
    }
}

1;
