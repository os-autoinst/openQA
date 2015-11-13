function setupAdminNeedles() {
    var table = $('#needles').DataTable(
	{ "ajax": $('#needles').data('ajax-url'),
	  deferRender: true,
	  "columns": [
	      { "data": "directory" },
	      { "data": "filename" },
	      { "data": "last_seen" },
	      { "data": "last_match" }
	  ],
	  
	  "order": [[0, "asc"], [1, "asc"]] ,
          "columnDefs": [
              { targets: [2,3],
                className: "time",
		"render": function ( data, type, row ) {
                    if (type === 'display' && data != 'never') {
                        var ri = 'last_seen_link';
                        if (data == row['last_match'])
                            ri = 'last_match_link';
                        return "<a href='" + row[ri] + "'>" + jQuery.timeago(new Date(data)) + "</a>";
                    } else
                        return data;
                }
              },
          ]
        }
    );
    function reloadNeedlesTable() {
	var url = $('#needles').data('ajax-url');
	url = url + "?last_match=" + $('#last_match_filter').val() + "&last_seen=" + $('#last_seen_filter').val();
	table.ajax.url(url);
	table.ajax.reload();
    }
    $('#last_seen_filter').change(reloadNeedlesTable);
    $('#last_match_filter').change(reloadNeedlesTable);
}
