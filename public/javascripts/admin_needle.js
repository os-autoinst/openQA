function setupAdminNeedles() {
    $('#needles').DataTable( { "order": [[2, "desc"],[0, "asc"]] ,
			       "columnDefs": [
				   { targets: [1, 2],
				     className: "time",
				     "render": function ( data, type, row ) {
					 if (type === 'display' && data != 'never') {
					     return jQuery.timeago(new Date(data));
					 } else
					     return data;
				     }
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
}
