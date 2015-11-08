function setupAdminNeedles() {
    $('#needles').hide();
    $('#needles').DataTable( { "order": [[2, "desc"],[0, "asc"]] ,
			       "columnDefs": [
				   { targets: [1, 3],
				     className: "time",
				     "render": function ( data, type, row ) {
					 if (type === 'display' && data != 'never') {
					     var ri = 2;
					     if (data == row[3])
						 ri = 4;
					     return "<a href='" + row[ri] + "'>" + jQuery.timeago(new Date(data)) + "</a>";
					 } else
					     return data;
				     }
				   },
				   {  "targets": [ 2, 4 ],
				      "visible": false,
				   },
				   { targets: 0,
				     className: "filename",
				     "render": function ( data, type, row ) {
					 if (type === 'display') {
					     return data.split('/').pop().slice(0, -5);
					 } else
					     return data;
				     }
				   }
			       ]
			     }
			   );
    $('#needles').show();
}
