function setupWorkerNeedles() {

    var table = $('#previous_jobs').DataTable(
        { "ajax": $('#previous_jobs').data('ajax-url'),
            deferRender: true,
            "columns": [
                {"data": "id"},
                {"data": "name", "orderable": false},
                {"data": "result"},
                {"data": "created"}
            ],
            "processing": true,
            "serverSide": true,
            "order": [[3, "desc"], [0, "asc"]],
            "columnDefs": [
            {  "targets": [0],
                "className": "time",
                "render": function (data, type, row) {
                    return "<a href=\"/tests/" + data + "\">" + data + "</a>";
                }
            },
            {  "targets": [3],
                "className": "time",
                "render": function (data, type, row) {
                    return jQuery.timeago(new Date(data));
                }
            }
            ]
        });

    $('#previous_jobs_filter').hide();
}
