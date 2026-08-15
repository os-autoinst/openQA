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
  const previousJobsEl = document.getElementById('previous_jobs');
  if (!previousJobsEl) return;
  const table = new DataTable('#previous_jobs', {
    ajax: previousJobsEl.dataset.ajaxUrl,
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
  const filter = document.getElementById('previous_jobs_filter');
  if (filter) filter.style.display = 'none';
}

// a reserved worker running a job is labelled "Working (Reserved)" and matches both filters on purpose
const WORKER_STATUS_FILTERS = ['Idle', 'Offline', 'Working', 'Unavailable', 'Reserved'];
const DEFAULT_WORKER_STATUS_FILTER = 'Idle';

function filterWorkerStatus(column, status) {
  column.search(status ? '\\b' + status + '\\b' : '', true, false).draw();
}

function loadWorkerTable() {
  const table = new DataTable('#workers', {
    initComplete: function () {
      this.api()
        .columns()
        .every(function () {
          const column = this;
          const colheader = this.header();
          const title = colheader.textContent.trim();
          if (title !== 'Status') return;

          colheader.innerHTML = '';
          const select = document.createElement('select');
          select.id = 'workers_online';
          const allOption = document.createElement('option');
          allOption.value = '';
          allOption.textContent = 'All';
          select.appendChild(allOption);
          colheader.appendChild(select);

          select.addEventListener('change', function () {
            filterWorkerStatus(column, this.value);
          });

          WORKER_STATUS_FILTERS.forEach(val => {
            const opt = document.createElement('option');
            opt.value = val;
            opt.textContent = val;
            select.appendChild(opt);
          });
          select.value = DEFAULT_WORKER_STATUS_FILTER;
          filterWorkerStatus(column, DEFAULT_WORKER_STATUS_FILTER);
        });
    }
  });

  // prevent sorting when worker status selection clicked
  document.addEventListener('click', function (event) {
    if (event.target.id === 'workers_online') {
      event.stopPropagation();
    }
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

function usePresetDuration(select) {
  if (select.value) {
    const reserveDuration = document.getElementById('reserveDuration');
    if (reserveDuration) reserveDuration.value = select.value;
  }
}

function openExtendModal(extendBtn) {
  const duration = document.getElementById('reserveDuration');
  const mode = document.getElementById('reserveMode');
  const modalLabel = document.getElementById('reserveModalLabel');
  const workerId = document.getElementById('reserveWorkerId');
  const workerName = document.getElementById('reserveWorkerName');
  const commentGroup = document.getElementById('reserveCommentGroup');
  const comment = document.getElementById('reserveComment');
  const durationLabel = document.getElementById('reserveDurationLabel');
  const durationPreset = document.getElementById('reserveDurationPreset');
  const forceGroup = document.getElementById('reserveForceGroup');
  const submitBtn = document.getElementById('reserveSubmitBtn');

  if (mode) mode.value = 'extend';
  if (modalLabel) modalLabel.textContent = 'Extend Reservation';
  if (workerId) workerId.value = extendBtn.dataset.workerId;
  if (workerName) workerName.value = extendBtn.dataset.workerName || '';
  if (commentGroup) commentGroup.style.display = 'none';
  if (comment) comment.required = false;
  if (durationLabel) durationLabel.textContent = 'Extend by (e.g. 2h, 30m, 1d)';
  if (duration) duration.value = '2h';
  if (durationPreset) durationPreset.value = '2h';
  if (forceGroup) forceGroup.style.display = 'none';
  if (submitBtn) submitBtn.textContent = 'Extend';

  const modalEl = document.getElementById('reserveModal');
  if (modalEl) new bootstrap.Modal(modalEl).show();
}

function openReserveModal(reserveBtn) {
  const duration = document.getElementById('reserveDuration');
  const mode = document.getElementById('reserveMode');
  const modalLabel = document.getElementById('reserveModalLabel');
  const workerId = document.getElementById('reserveWorkerId');
  const workerName = document.getElementById('reserveWorkerName');
  const commentGroup = document.getElementById('reserveCommentGroup');
  const comment = document.getElementById('reserveComment');
  const durationLabel = document.getElementById('reserveDurationLabel');
  const durationPreset = document.getElementById('reserveDurationPreset');
  const forceGroup = document.getElementById('reserveForceGroup');
  const force = document.getElementById('reserveForce');
  const submitBtn = document.getElementById('reserveSubmitBtn');

  const workerClass = document.getElementById('reserveWorkerClass');
  if (workerClass) workerClass.value = '';
  const modalFlash = document.getElementById('reserveModalFlash');
  if (modalFlash) modalFlash.replaceChildren();

  if (mode) mode.value = 'reserve';
  if (modalLabel) modalLabel.textContent = 'Reserve Worker';
  if (workerId) workerId.value = reserveBtn.dataset.workerId;
  if (workerName) workerName.value = reserveBtn.dataset.workerName;
  if (commentGroup) commentGroup.style.display = 'block';
  if (comment) {
    comment.required = true;
    comment.value = '';
  }
  if (durationLabel) durationLabel.textContent = 'Duration (e.g. 5h, 2d, 3600; 0 for indefinite)';
  if (duration) duration.value = duration.dataset.defaultDuration || '';
  if (durationPreset) durationPreset.value = '';
  if (forceGroup) forceGroup.style.display = 'block';
  if (force) force.checked = false;
  if (submitBtn) submitBtn.textContent = 'Reserve';

  const host = reserveBtn.dataset.workerHost;
  const scopeContainer = document.getElementById('reserveScopeContainer');
  const reserveHostInput = document.getElementById('reserveHostName');
  if (host) {
    document.getElementById('reserveScopeHostName').textContent = host;
    reserveHostInput.value = host;
    document.getElementById('reserveScopeInstance').checked = true;
    scopeContainer.style.display = 'block';
  } else {
    scopeContainer.style.display = 'none';
    reserveHostInput.value = '';
  }

  const modalEl = document.getElementById('reserveModal');
  if (modalEl) new bootstrap.Modal(modalEl).show();
}

function openHostReserveModal(host, count) {
  const duration = document.getElementById('reserveDuration');
  duration.value = duration.dataset.defaultDuration;
  document.getElementById('reserveWorkerId').value = '';
  document.getElementById('reserveWorkerName').value = 'All ' + count + ' instances on ' + host;
  document.getElementById('reserveComment').value = '';
  document.getElementById('reserveWorkerClass').value = '';
  document.getElementById('reserveModalFlash').replaceChildren();
  const force = document.getElementById('reserveForce');
  if (force) force.checked = false;

  document.getElementById('reserveScopeContainer').style.display = 'none';
  document.getElementById('reserveHostName').value = host;
  document.getElementById('reserveScopeHost').checked = true;

  new bootstrap.Modal(document.getElementById('reserveModal')).show();
}

function submitReserve(event) {
  event.preventDefault();
  const modeEl = document.getElementById('reserveMode');
  const workerIdEl = document.getElementById('reserveWorkerId');
  if (!modeEl || !workerIdEl) return;

  const mode = modeEl.value;
  const workerId = workerIdEl.value;
  const durationEl = document.getElementById('reserveDuration');
  const duration = durationEl ? durationEl.value : '';

  document.getElementById('reserveModalFlash').replaceChildren();

  const isHostScope = document.getElementById('reserveScopeHost').checked;
  const hostName = document.getElementById('reserveHostName').value;
  const url =
    isHostScope && hostName
      ? '/api/v1/worker_hosts/' + hostName + '/reservation'
      : reservationUrl(document.getElementById('reserveWorkerId').value);

  if (mode === 'extend') {
    const body = new URLSearchParams({by: duration});
    const options = {method: 'POST', headers: {'Content-Type': 'application/x-www-form-urlencoded'}, body};
    requestWorkerChange(
      reservationUrl(workerId) + '/extend',
      options,
      "The reservation couldn't be extended: ",
      () => window.location.reload(),
      error =>
        addFlash(
          'danger',
          "The reservation couldn't be extended: " + error,
          document.getElementById('reserveModalFlash')
        )
    );
  } else {
    const commentEl = document.getElementById('reserveComment');
    const forceEl = document.getElementById('reserveForce');
    const workerClassEl = document.getElementById('reserveWorkerClass');
    const comment = commentEl ? commentEl.value : '';
    const force = forceEl && forceEl.checked ? 1 : 0;
    const worker_class = workerClassEl ? workerClassEl.value : '';

    const body = new URLSearchParams({comment, duration, worker_class, force});
    const options = {method: 'POST', headers: {'Content-Type': 'application/x-www-form-urlencoded'}, body};
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
    deleteBtn.getAttribute('post_delete_url'),
    {method: 'DELETE'},
    "The worker couldn't be deleted: ",
    response => {
      const table = new DataTable('#workers');
      const tr = deleteBtn.closest('tr');
      if (tr) table.row(tr).remove().draw();
      addFlash('info', response.message);
    }
  );
}

window.setupWorkerNeedles = setupWorkerNeedles;
window.loadWorkerTable = loadWorkerTable;
window.deleteWorker = deleteWorker;
window.openReserveModal = openReserveModal;
window.submitReserve = submitReserve;
window.releaseWorker = releaseWorker;
window.openExtendModal = openExtendModal;
window.usePresetDuration = usePresetDuration;
