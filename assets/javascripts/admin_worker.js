function setupWorkerNeedles() {

    var table = $('#previous_jobs').DataTable(
        {ajax: $('#previous_jobs').data('ajax-url'),
            deferRender: true,
            "columns": [
                {data: "name", orderable: false},
                {data: "result_stats"},
                {data: "finished"}
            ],
            processing: true,
            serverSide: true,
            order: [[2, "desc"]],
            columnDefs: [
                {targets: 0, render: renderTestName},
                {targets: 1, render: renderTestResult},
                {targets: 2, render: renderTimeAgo}
            ]
        });
    table.on('draw.dt', setupTestButtons);
    $('#previous_jobs_filter').hide();
}
