function renderTestsList(jobs, is_operator, restart_url, prio_url, cancel_url) {

    var result_table = $('#results').DataTable( {
	"dom": 'l<"#toolbar">frtip',
	"lengthMenu": [[10, 25, 50], [10, 25, 50]],
	"ajax": {
	    "url": "/tests/list_ajax",
	    "type": "POST", // we use POST as the URLs can get long
	    "data": function(d) {
		var ret = {
		    "relevant": $('#relevantfilter').prop('checked'),
            "state" : 'done'
		};
		if (jobs != null) {
		    ret['jobs'] = jobs;
		    ret['initial'] = 1;
		}
		// reset for reload
		jobs = null;
		return ret;
	    }
	},
	// no initial resorting
	"order": [],
	"columns": [
	    { "data": "name" },
	    { "data": "test" },
	    { "data": "deps" },
	    { "data": "testtime" },
	    { "data": "result_stats" },
	],
	"columnDefs": [
	    { targets: 0,
	      className: "name",
	      "render": function ( data, type, row ) {
		  var name = 'Build' + row['build'];
		  name += " of ";
		  return name + row['distri'] + "-" + row['flavor'] + "." + row['arch'];
	      },
	    },
	    { targets: 1,
	      className: "test",
	      "render": function ( data, type, row ) {
		  if (type === 'display') {
		      html = '<a class="overview_' + row['result'] + '" href="/tests/' + row['id'] + '">' + data + '</a>';
		      if (row['clone']) {
                          html += ' <a href="/tests/' + row['clone'] + '">(restarted)</a>';
                      } else if (is_operator) {
			  var url = restart_url.replace('REPLACEIT', row['id']);
                          html += ' <a data-method="POST" data-remote="true" class="api-restart" href="' + url + '">' +
                              '<i class="fa fa-repeat" title="Restart Job"></i></a>'
		      }
                      return html;
		  } else {
		      return data;
		  }
              },
	    },
	    { targets: 3,
	      "render": function ( data, type, row ) {
		  if (type === 'display')
		      return jQuery.timeago(data + " UTC");
		  else
		      return data;
	      }
	    },
	    { targets: 4,
	      "render": function ( data, type, row ) {
		  if (type === 'display') {
		      var html = data['passed'] + "<i class='fa fa-star'></i>";
		      if (data['dents']) {
			  html +=  " " + data['dents'] + "<i class='fa fa-star-half-empty'></i> ";
		      }
		      if (data['failed']) {
			  html +=  " " + data['failed'] + "<i class='fa fa-star-o'></i> ";
		      }
		      if (data['none']) {
			  html +=  " " + data['none'] + "<i class='fa fa-ban'></i> ";
		      }
                      return '<a class="overview_' + row['result'] + '" href="/tests/' + row['id'] + '">' + html + '</a>';
		  } else {
		      return (parseInt(data['passed']) * 10000) + (parseInt(data['dents']) * 100) + parseInt(data['failed']);
		  }
              }
	    },
	],
    } );

    var scheduled_table = $('#scheduled').DataTable( {
        "pagingType" : 'simple',
        "order": [[3, 'asc'], [0, 'asc']],
        "ajax": {
            "url": "/tests/list_ajax",
            "type": "POST", // we use POST as the URLs can get long
            "data": function(d) {
            var ret = {
                "relevant": $('#relevantfilter').prop('checked'),
                "state" : 'scheduled'
            };
            if (jobs != null) {
                ret['jobs'] = jobs;
                ret['initial'] = 1;
            }
            // reset for reload
            jobs = null;
            return ret;
            }
        },
        "columns": [
            { "data": "name" },
            { "data": "test" },
            { "data": "deps" },
            { "data": "priority" },
        ],
        "columnDefs": [
            { targets: 0,
                className: "name",
                "render": function ( data, type, row ) {
                var name = 'Build' + row['build'];
                name += " of ";
                return name + row['distri'] + "-" + row['flavor'] + "." + row['arch'];
                },
            },
            { targets: 1,
                className: "test",
                "render": function ( data, type, row ) {
                    if (type === 'display') {
                        return '<a class="overview_' + row['result'] + '" href="/tests/' + row['id'] + '">' + data + '</a>';
                    } else {
                        return data;
                    }
                }
            },
            { targets: 3,
                className: "actions",
                "render": function ( data, type, row ) {
                    if (type === 'display') {
                        if (is_operator) {
                            var url_prio = prio_url.replace('REPLACEIT', row['id']);
                            var url_cancel = cancel_url.replace('REPLACEIT', row['id']);
                            var html = '<a data-method="POST" data-remote="true" class="api-prio" href="' + url_prio + '?prio=' + (row['priority'] - 10) + '"><i class="fa fa-minus-square-o"></i></a>';
                            html += '<span data-prio="' + row['priority'] + '">' + row['priority'] + '</span>';
                            html += '<a data-method="POST" data-remote="true" class="api-prio" href="' + url_prio + '?prio=' + (row['priority'] + 10) + '"><i class="fa fa-plus-square-o"></i></a>';
                            html += '<a data-method="POST" data-remote="true" class="api-cancel" href="' + url_cancel + '"><i class="fa fa-times-circle-o"></i></a>';
                            return html;
                        }
                        else {
                            return '<span data-prio="' + row['priority'] + '">' + row['priority'] + '</span>';
                        }
                    } else {
                        return data;
                    }
                }
            }
        ],
    } );
    $("#relevantbox").detach().appendTo('#toolbar');
    $('#relevantbox').css('display', 'inherit');
    // Event listener to the two range filtering inputs to redraw on input
    $('#relevantfilter').change( function() {
	$('#relevantbox').css('color', 'cyan');
        result_table.ajax.reload(function() {
	    $('#relevantbox').css('color', 'inherit');
	} );
    } );
    $(document).on("click", '.api-restart', function() {
        scheduled_table.ajax.reload(null, false);
        var link = $(this);
        $.post(link.attr("href")).done( function( data ) { console.log(link); $(link).replaceWith('(restarted)'); });
    });
    $(document).on("click", '.api-prio', function() {
        scheduled_table.ajax.reload(null, false);
    });
    $(document).on("click", '.api-cancel', function() {
        scheduled_table.ajax.reload(null, false);
        result_tablea.ajax.reload(null, false);
    });
};
