var audit_url;
var ajax_url;

function htmlEscape(str) {
    return String(str)
    .replace(/&/g, '&amp;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;');
}

// FIXME: this isn't working yet and is not active
function auditSeach(search_string) {
    var ids    = search_string.match(/id: ?([^ ]+)/g);
    var events = search_string.match(/event: ?([^ ]+)/g);
    var users  = search_string.match(/user: ?([^ ]+)/g);
    var conns  = search_string.match(/connection: ?([^ ]+)/g);
    $('#audit_log_table').DataTable().column(1).search(ids, null, true).column(4).search(events, null, true).column(2).search(users. null, true).column(3).search(conns, null, true);
    $('#audit_log_table').DataTable().draw();
}

$.fn.dataTable.ext.search.push(
    // TODO: patch in auditSearch
);

function loadAuditLogTable ()
{
    $('#audit_log_table').DataTable( {
    lengthMenu: [10, 25, 50],
    ajax: {
        url: ajax_url,
        type: "GET",
        dataType: 'json',
    },
    columns: [
        { data: 'event_time' },
        { data: 'user' },
        { data: 'connection' },
        { data: 'event' },
        { data: 'event_data' }
    ],
    order: [[0, 'desc']],
    columnDefs: [
        { 
            targets: 0,
            render: function ( data, type, row ) {
                if (type === 'display')
                    // I want to have a link to events for cases when one wants to share interesing event
                    return '<a href="' + audit_url + '?eventid=' + row.id + '">' + jQuery.timeago(data + " UTC") + '</a>';
                else
                    return data;
            }
        },
        { 
            targets: 4,
            render: function ( data, type, row ) {
                // Limit length of displayed event data, expand on click
                if (type === 'display' && data.length > 40)
                    return '<span id="audit_event_data" title="'+htmlEscape(data)+'">' + htmlEscape(data.substr( 0, 38 )) + '...</span>';
                else
                    return data;
            }
        },
    ],
    });
}