# Copyright 2016-2021 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Schema::ResultSet::JobSettings;
use Mojo::Base 'DBIx::Class::ResultSet', -signatures;

use OpenQA::App;
use List::Util qw(min);

sub all_values_sorted ($self, $job_id, $key) {
    state $options = {distinct => 1, columns => 'value', order_by => 'value'};
    [map { $_->value } $self->search({job_id => $job_id, key => $key}, $options)];
}

sub jobs_for_setting_by_exact_key_and_value ($self, $key, $value, $limit) {
    my $limits = OpenQA::App->singleton->config->{misc_limits};
    $limit = min($limits->{generic_max_limit}, $limit // $limits->{generic_default_limit});
    my $options = {columns => ['job_id'], rows => $limit, order_by => {-desc => 'id'}};
    return [map { $_->job_id } $self->search({key => $key, value => $value}, $options)];
}

sub jobs_for_setting ($self, $options) {
    # Return jobs for settings specified by a concrete key/value pair
    my $value = $options->{value};
    my $limit = $options->{limit};
    return $self->jobs_for_setting_by_exact_key_and_value($options->{key}, $value, $limit) if defined $value;

    # Return jobs for settings specified by a key with globbing and a value that can be part of a comma-separated list
    my $server_side_limit = OpenQA::App->singleton->config->{misc_limits}{job_settings_max_recent_jobs};
    $limit = min($server_side_limit, defined($limit) ? ($limit) : ());
    my $key_like = $options->{key};
    $key_like =~ s/\*/\%/g;
    my $list_value = $options->{list_value};
    my $list_value_like = "%${list_value}%";
    my $list_result = $options->{list_result};

    # Get the highest job id to limit the number of jobs that need to be considered (to improve performance)
    my $dbh = $self->result_source->schema->storage->dbh;
    my $sth = $dbh->prepare('SELECT max(job_id) FROM job_settings');
    $sth->execute;

    my $result = $sth->fetchrow_arrayref;
    my $max_id = defined $result ? $result->[0] : 0;
    my $min_id = $max_id > $limit ? $max_id - $limit : 0;

    my @where_queries = ('js.key LIKE ?', 'js.value LIKE ?', 'js.job_id > ?');
    my @where_values = ($key_like, $list_value_like, $min_id);
    my $join_part = '';
    if (defined $list_result) {
        $join_part = 'JOIN jobs j ON js.job_id = j.id';
        my $placeholders = join(',', ('?') x scalar @$list_result);
        push @where_queries, "j.result IN ($placeholders)";
        push @where_values, @$list_result;
    }
    # Instead of limiting the number of jobs, this query could also use a trigram gin index to achieve even better
    # performance (at the cost of disk space and setup complexity)
    my $where_queries = 'WHERE ' . join(' AND ', @where_queries);
    my $sql = "SELECT js.job_id, js.value
               FROM job_settings js
               $join_part
               $where_queries
               ORDER BY js.job_id DESC";
    $sth = $dbh->prepare($sql);
    $sth->execute(@where_values);
    #$sth = $dbh->prepare(
   #    'SELECT job_id, value FROM job_settings WHERE key LIKE ? AND value LIKE ? AND job_id > ? ORDER BY job_id DESC');
    #$sth->execute($key_like, $list_value_like, $min_id);

    # Match list values
    my @jobs;
    for my $row (@{$sth->fetchall_arrayref}) {
        my ($job_id, $value) = @$row;
        push @jobs, $job_id if $value =~ /(?:^|,)$list_value(?:$|,)/;
    }
    return \@jobs;
}

=head2 query_for_settings

=over

=item Return value: ResultSet (to be used as subquery)

=back

Given a perl hash, will create a ResultSet of job_settings

=cut

sub query_for_settings ($self, $args) {
    my @conds;
    # Search into the following job_settings
    for my $setting (keys %$args) {
        next unless $args->{$setting};
        # for dynamic self joins we need to be creative ;(
        my $tname = 'me';
        my $setting_value = ($args->{$setting} =~ /^:\w+:/) ? {'like', "$&%"} : $args->{$setting};
        push(
            @conds,
            {
                "$tname.key" => $setting,
                "$tname.value" => $setting_value
            });
    }
    return $self->search({-and => \@conds});
}

1;
