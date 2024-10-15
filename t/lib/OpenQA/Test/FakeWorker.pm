package OpenQA::Test::FakeWorker;
use Mojo::Base -base, -signatures;

{
    package Test::FakeSettings;
    use Mojo::Base -base;
    has global_settings => sub { {RETRIES => 3, RETRY_DELAY => 10, RETRY_DELAY_IF_WEBUI_BUSY => 90} };
    has webui_host_specific_settings => sub { {} };
}

has pool_directory => undef;
has instance_number => 1;
has worker_hostname => 'test_host';
has current_webui_host => undef;
has capabilities => sub { {fake_capabilities => 1} };
has stop_current_job_called => 0;
has is_stopping => 0;
has skipped_jobs => sub { [] };
has current_error => undef;
has current_job => undef;
has pending_job => undef;
has has_pending_jobs => 0;
has pending_job_ids => sub { [] };
has current_job_ids => sub { [] };
has is_busy => 0;
has settings => sub { Test::FakeSettings->new };
has enqueued_job_info => undef;
has is_executing_single_job => 1;

sub stop_current_job ($self, $reason) { $self->stop_current_job_called($reason) }
sub stop ($self) { $self->is_stopping(1) }
sub status ($self) { {fake_status => 1, reason => 'some error'} }
sub accept_job ($self, $client, $job_info) {
    $self->current_job(OpenQA::Worker::Job->new($self, $client, $job_info));
}
sub enqueue_jobs_and_accept_first ($self, $client, $job_info) {
    $self->enqueued_job_info($job_info);
}
sub skip_job ($self, $job_id, $type) { push @{$self->skipped_jobs}, [$job_id, $type] }
sub find_current_or_pending_job ($self, $job_id) {
    return undef unless my $current_job = $self->current_job;
    return $current_job if $current_job->id eq $job_id;
    return undef unless my $pending_job = $self->pending_job;
    return $pending_job if $pending_job->id eq $job_id;
}

1;
