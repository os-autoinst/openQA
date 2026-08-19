function setupWorkerNeedles() {
  const table = $('#previous_jobs').DataTable({
    ajax: $('#previous_jobs').data('ajax-url'),
    deferRender: true,
    columns: [{data: 'name'}, {data: 'result_stats'}, {data: 'finished'}],
    processing: true,
    serverSide: true,
    order: [[2, 'desc']],
    columnDefs: [
      {
        targets: 0,
        className: 'test',
        render: renderTestName
      },
      {targets: 1, render: renderTestResult},
      {targets: 2, render: renderTimeAgo}
    ]
  });
  table.on('draw.dt', setupTestButtons);
  $('#previous_jobs_filter').hide();
}

// a reserved worker running a job is labelled "Working (Reserved)" and matches both filters on purpose
const WORKER_STATUS_FILTERS = ['Idle', 'Offline', 'Working', 'Unavailable', 'Reserved'];
const DEFAULT_WORKER_STATUS_FILTER = 'Idle';

function filterWorkerStatus(column, status) {
  column.search(status ? '\\b' + status + '\\b' : '', true, false).draw();
}

function loadWorkerTable() {
  $('#workers').DataTable({
    initComplete: function () {
      this.api()
        .columns()
        .every(function () {
          const column = this;
          if ($(this.header()).text().trim() !== 'Status') return;
          const options = WORKER_STATUS_FILTERS.map(s => `<option value="${s}">${s}</option>`).join('');
          $(`<select id="workers_online"><option value="">All</option>${options}</select>`)
            .appendTo($(column.header()).empty())
            .on('change', function () {
              filterWorkerStatus(column, $(this).val());
            })
            .val(DEFAULT_WORKER_STATUS_FILTER);
          filterWorkerStatus(column, DEFAULT_WORKER_STATUS_FILTER);
        });
    }
  });

  // prevent sorting when worker status selection clicked
  $('#workers_online').on('click', function (event) {
    event.stopPropagation();
  });
}

function requestWorkerChange(url, options, failureMessage, onSuccess) {
  fetchWithCSRF(url, options)
    .then(response => response.json())
    .then(response => {
      if (response.error) throw response.error;
      onSuccess(response);
    })
    .catch(error => {
      addFlash('danger', failureMessage + error);
    });
}

function reservationUrl(workerId) {
  return '/api/v1/workers/' + workerId + '/reservation';
}

function openReserveModal(reserveBtn) {
  const duration = document.getElementById('reserveWorkerDuration');
  document.getElementById('reserveWorkerId').value = reserveBtn.dataset.workerId;
  document.getElementById('reserveWorkerName').value = reserveBtn.dataset.workerName;
  document.getElementById('reserveWorkerComment').value = '';
  duration.value = duration.dataset.defaultDuration;
  const force = document.getElementById('reserveWorkerForce');
  if (force) force.checked = false;
  new bootstrap.Modal(document.getElementById('reserveWorkerModal')).show();
}

function submitReserve(event) {
  event.preventDefault();
  const force = document.getElementById('reserveWorkerForce');
  const body = new URLSearchParams({
    comment: document.getElementById('reserveWorkerComment').value,
    duration: document.getElementById('reserveWorkerDuration').value,
    force: force && force.checked ? 1 : 0
  });
  const options = {method: 'POST', headers: {'Content-Type': 'application/x-www-form-urlencoded'}, body};
  requestWorkerChange(
    reservationUrl(document.getElementById('reserveWorkerId').value),
    options,
    "The worker couldn't be reserved: ",
    () => window.location.reload()
  );
}

function releaseWorker(releaseBtn) {
  requestWorkerChange(
    reservationUrl(releaseBtn.dataset.workerId),
    {method: 'DELETE'},
    "The worker reservation couldn't be released: ",
    () => window.location.reload()
  );
}

function deleteWorker(deleteBtn) {
  requestWorkerChange(
    $(deleteBtn).attr('post_delete_url'),
    {method: 'DELETE'},
    "The worker couldn't be deleted: ",
    response => {
      $('#workers').DataTable().row($(deleteBtn).parents('tr')).remove().draw();
      addFlash('info', response.message);
    }
  );
}
