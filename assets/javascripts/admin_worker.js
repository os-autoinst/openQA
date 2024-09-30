function setupWorkerNeedles() {
  var table = $('#previous_jobs').DataTable({
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

function loadWorkerTable() {
  $('#workers').DataTable({
    initComplete: function () {
      this.api()
        .columns()
        .every(function () {
          var column = this;
          var colheader = this.header();
          var title = $(colheader).text().trim();
          if (title !== 'Status') {
            return false;
          }

          var select = $('<select id="workers_online"><option value="">All</option></select>')
            .appendTo($(column.header()).empty())
            .on('change', function () {
              var val = $.fn.dataTable.util.escapeRegex($(this).val());
              column
                // .search( val ? '^'+val+'$' : '', true, false )
                .search(val ? val : '', true, false)
                .draw();
            });

          select.append('<option value="Idle">Idle</option>');
          select.append('<option value="Offline">Offline</option>');
          select.append('<option value="Working">Working</option>');
          select.append('<option value="Broken">Broken</option>');
          select.val('Idle');
        });
      this.api().column(4).search('Idle').draw();
    }
  });

  // prevent sorting when worker status selection clicked
  $('#workers_online').on('click', function (event) {
    event.stopPropagation();
  });
}

function deleteWorker(deleteBtn) {
  var post_url = $(deleteBtn).attr('post_delete_url');
  fetchWithCSRF(post_url, {method: 'DELETE'})
    .then(response => {
      return response.json();
    })
    .then(response => {
      if (response.error) throw response.error;
      var table = $('#workers').DataTable();
      table.row($(deleteBtn).parents('tr')).remove().draw();
      addFlash('info', response.message);
    })
    .catch(error => {
      addFlash('danger', "The worker couldn't be deleted: " + error);
    });
}
