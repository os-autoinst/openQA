function setupHostPreviousJobs() {
  if (!$('#previous_host_jobs').length) return;
  const table = $('#previous_host_jobs').DataTable({
    ajax: $('#previous_host_jobs').data('ajax-url'),
    deferRender: true,
    columns: [{data: 'name'}, {data: 'worker'}, {data: 'result_stats'}, {data: 'finished'}],
    processing: true,
    serverSide: true,
    order: [[3, 'desc']],
    columnDefs: [
      {
        targets: 0,
        className: 'test',
        render: renderTestName
      },
      {
        targets: 1,
        render: data => (data ? ':' + data : '')
      },
      {targets: 2, render: renderTestResult},
      {targets: 3, render: renderTimeAgo}
    ]
  });
  table.on('draw.dt', setupTestButtons);
  $('#previous_host_jobs_filter').hide();
}

function setupWorkerNeedles() {
  setupHostPreviousJobs();
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
  const table = $('#workers').DataTable({
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

  setupTablePersistence(table, {
    customFilters: {
      status: {column: 4, element: '#workers_online', defaultValue: 'Idle'}
    }
  });
}

function requestWorkerChange(url, options, failureMessage, onSuccess, onError = null) {
  fetchWithCSRF(url, options)
    .then(response => response.json())
    .then(response => {
      if (response.error) throw response.error;
      onSuccess(response);
    })
    .catch(error => {
      if (onError) onError(error);
      else addFlash('danger', failureMessage + error);
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
  const workerClass = document.getElementById('reserveWorkerClass');
  if (workerClass) workerClass.value = '';
  const modalFlash = document.getElementById('reserveModalFlash');
  if (modalFlash) modalFlash.replaceChildren();
  duration.value = duration.dataset.defaultDuration;
  const force = document.getElementById('reserveWorkerForce');
  if (force) force.checked = false;

  const host = reserveBtn.dataset.workerHost;
  const scopeContainer = document.getElementById('reserveScopeContainer');
  const hostNameSpan = document.getElementById('reserveScopeHostName');
  const reserveHostInput = document.getElementById('reserveHostName');
  if (scopeContainer && host) {
    hostNameSpan.textContent = host;
    reserveHostInput.value = host;
    document.getElementById('reserveScopeInstance').checked = true;
    scopeContainer.style.display = 'block';
  } else if (scopeContainer) {
    scopeContainer.style.display = 'none';
    reserveHostInput.value = '';
  }

  new bootstrap.Modal(document.getElementById('reserveWorkerModal')).show();
}

function openHostReserveModal(host, count) {
  const duration = document.getElementById('reserveWorkerDuration');
  document.getElementById('reserveWorkerId').value = '';
  document.getElementById('reserveWorkerName').value = 'All ' + count + ' instances on ' + host;
  document.getElementById('reserveWorkerComment').value = '';
  const workerClass = document.getElementById('reserveWorkerClass');
  if (workerClass) workerClass.value = '';
  const modalFlash = document.getElementById('reserveModalFlash');
  if (modalFlash) modalFlash.replaceChildren();
  duration.value = duration.dataset.defaultDuration;
  const force = document.getElementById('reserveWorkerForce');
  if (force) force.checked = false;

  const scopeContainer = document.getElementById('reserveScopeContainer');
  const reserveHostInput = document.getElementById('reserveHostName');
  if (scopeContainer) {
    scopeContainer.style.display = 'none';
  }
  if (reserveHostInput) {
    reserveHostInput.value = host;
  }
  const hostRadio = document.getElementById('reserveScopeHost');
  if (hostRadio) {
    hostRadio.checked = true;
  }

  new bootstrap.Modal(document.getElementById('reserveWorkerModal')).show();
}

function submitReserve(event) {
  event.preventDefault();
  const force = document.getElementById('reserveWorkerForce');
  const workerClass = document.getElementById('reserveWorkerClass');
  const body = new URLSearchParams({
    comment: document.getElementById('reserveWorkerComment').value,
    duration: document.getElementById('reserveWorkerDuration').value,
    worker_class: workerClass ? workerClass.value : '',
    force: force && force.checked ? 1 : 0
  });
  const options = {method: 'POST', headers: {'Content-Type': 'application/x-www-form-urlencoded'}, body};

  const modalFlash = document.getElementById('reserveModalFlash');
  if (modalFlash) modalFlash.replaceChildren();

  const isHostScope = document.getElementById('reserveScopeHost')?.checked;
  const hostName = document.getElementById('reserveHostName')?.value;
  const url =
    isHostScope && hostName
      ? '/api/v1/worker_hosts/' + hostName + '/reservation'
      : reservationUrl(document.getElementById('reserveWorkerId').value);

  requestWorkerChange(
    url,
    options,
    "The reservation couldn't be performed: ",
    () => window.location.reload(),
    error =>
      addFlash(
        'danger',
        "The reservation couldn't be performed: " + error,
        document.getElementById('reserveModalFlash')
      )
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

function releaseHost(host) {
  requestWorkerChange(
    '/api/v1/worker_hosts/' + host + '/reservation',
    {method: 'DELETE'},
    "The worker host reservation couldn't be released: ",
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
