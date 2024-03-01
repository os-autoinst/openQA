# Copyright 2016-2021 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Schema::ResultSet::JobSettings;
use Mojo::Base 'DBIx::Class::ResultSet', -signatures;

use OpenQA::App;

sub jobs_for_setting ($self, $options) {
    my $limit = OpenQA::App->singleton->config->{misc_limits}{job_settings_max_recent_jobs};

    my $key_like = $options->{key};
    $key_like =~ s/\*/\%/g;
    my $list_value = $options->{list_value};
    my $list_value_like = "%${list_value}%";
    my $filter_results = $options->{filter_results} if $options->{filter_results};
    my $groupids = $options->{gids} if $options->{gids};

    # Get the highest job id to limit the number of jobs that need to be considered (to improve performance)
    my $dbh = $self->result_source->schema->storage->dbh;
    my $sth = $dbh->prepare('SELECT max(job_id) FROM job_settings');
    $sth->execute;

    my $result = $sth->fetchrow_arrayref;
    my $max_id = defined $result ? $result->[0] : 0;
    my $min_id = $max_id > $limit ? $max_id - $limit : 0;

    # Instead of limiting the number of jobs, this query could also use a trigram gin index to achieve even better
    # performance (at the cost of disk space and setup complexity)
    if ($filter_results && $groupids) {
	$sth = $dbh->prepare(
        'SELECT job_id, value FROM job_settings INNER JOIN jobs ON jobs.id=job_settings.job_id WHERE key LIKE ? AND value LIKE ? AND jobs.result = ? AND jobs.group_id = ? AND job_id > ? ORDER BY job_settings.job_id DESC');
	$sth->execute($key_like, $list_value_like, $filter_results, $groupids, $min_id);
    } else {
	$sth = $dbh->prepare(
        'SELECT job_id, value FROM job_settings WHERE key LIKE ? AND value LIKE ? AND job_id > ? ORDER BY job_id DESC');
	$sth->execute($key_like, $list_value_like, $min_id);
    }
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
