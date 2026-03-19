function setupWorkerNeedles() {
  const previousJobsEl = document.getElementById('previous_jobs');
  if (!previousJobsEl) return;
  var table = new DataTable('#previous_jobs', {
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

function loadWorkerTable() {
  new DataTable('#workers', {
    initComplete: function () {
      this.api()
        .columns()
        .every(function () {
          var column = this;
          var colheader = this.header();
          var title = colheader.textContent.trim();
          if (title !== 'Status') {
            return false;
          }

          colheader.innerHTML = '';
          var select = document.createElement('select');
          select.id = 'workers_online';
          const allOption = document.createElement('option');
          allOption.value = '';
          allOption.textContent = 'All';
          select.appendChild(allOption);
          colheader.appendChild(select);

          select.addEventListener('change', function () {
            var val = DataTable.util.escapeRegex(this.value);
            column.search(val ? val : '', true, false).draw();
          });

          ['Idle', 'Offline', 'Working', 'Unavailable'].forEach(val => {
            const opt = document.createElement('option');
            opt.value = val;
            opt.textContent = val;
            select.appendChild(opt);
          });
          select.value = 'Idle';
        });
      this.api().column(4).search('Idle').draw();
    }
  });

  // prevent sorting when worker status selection clicked
  document.addEventListener('click', function (event) {
    if (event.target.id === 'workers_online') {
      event.stopPropagation();
    }
  });
}

function deleteWorker(deleteBtn) {
  var post_url = deleteBtn.getAttribute('post_delete_url');
  fetchWithCSRF(post_url, {method: 'DELETE'})
    .then(response => {
      return response.json();
    })
    .then(response => {
      if (response.error) throw response.error;
      var table = new DataTable('#workers');
      const tr = deleteBtn.closest('tr');
      if (tr) table.row(tr).remove().draw();
      addFlash('info', response.message);
    })
    .catch(error => {
      addFlash('danger', "The worker couldn't be deleted: " + error);
    });
}
