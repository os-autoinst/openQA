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

function loadAuditLogTable ()
{
    $('#audit_log_table').DataTable( {
    lengthMenu: [20, 40, 100],
    processing: true,
    serverSide: true,
    search: {
        search: searchquery,
    },
    ajax: {
        url: ajax_url,
        type: "GET",
        dataType: 'json'
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
                    return '<a href="' + audit_url + '?eventid=' + row.id + '" title=' + data + '>' + jQuery.timeago(data + " UTC") + '</a>';
                else
                    return data;
            }
        },
        {
            targets: 2,
            visible: false
        },
        {
            targets: 4,
            width: "70%",
            render: function ( data, type, row ) {
                if (type === 'display' && data) {
                    var parsed_data;
                    try {
                        parsed_data = JSON.stringify(JSON.parse(data), null, 2);
                    } catch (e) {
                        parsed_data = data;
                    }
                    return '<span id="audit_event_data" title="' + htmlEscape(parsed_data) + '">' + htmlEscape(parsed_data) + '</span>';
                }
                else {
                    return data;
                }
            }
        },
    ],
    });
}

function loadProductLogTable ()
{
    var table = $('#product_log_table').DataTable( {
        lengthMenu: [10, 25, 50],
        order: [[1, 'desc']],
        columnDefs: [
        {
            targets: 0,
            visible: false,
            searchable: false
        },
        {
            targets: 1,
            render: function ( data, type, row ) {
                if (type === 'display')
                    return '<a href="' + audit_url + '?eventid=' + row[0] + '">' + jQuery.timeago(data + " UTC") + '</a>';
                else
                    return data;
            }
        },
        {
            targets: 2,
            render: function ( data, type, row ) {
                return jQuery.parseJSON(row[8]).DISTRI;
            }
        },
        {
            targets: 3,
            render: function ( data, type, row ) {
                return jQuery.parseJSON(row[8]).VERSION;
            }
        },
        {
            targets: 4,
            render: function ( data, type, row ) {
                return jQuery.parseJSON(row[8]).FLAVOR;
            }
        },
        {
            targets: 5,
            render: function ( data, type, row ) {
                return jQuery.parseJSON(row[8]).ARCH;
            }
        },
        {
            targets: 6,
            render: function ( data, type, row ) {
                var data_o = jQuery.parseJSON(row[8]);
                if (data_o.hasOwnProperty('BUILD')) {
                    return data_o.BUILD;
                }
                return '';
            }
        },
        {
            targets: 7,
            render: function ( data, type, row ) {
                var data_o = jQuery.parseJSON(row[8]);
                if (data_o.hasOwnProperty('ISO')) {
                    return data_o.ISO;
                }
                return '';
            }
        },
        {
            targets: 8,
            render: function ( data, type, row ) {
                if (type === 'display' && data.length > 40) {
                    var parsed_data = JSON.stringify(JSON.parse(data), null, 2);
                    return '<span class="audit_event_data" title="' + htmlEscape(parsed_data) + '">' + htmlEscape(parsed_data.substr( 0, 38 )) + '…</span>';
                }
                else
                    return data;
            }
        },
        ]
    });

    $(document).on('click', '.iso_restart', function(event) {
        event.preventDefault();
        var restart_link = $(this).attr('href');
        var action_cell = $(this).parent('td');
        var action_row = $(this).closest('tr');
        var event_data = table.row(action_row).data()[8];
        event_data = jQuery.parseJSON(event_data);
        $.post(restart_link, event_data).done( function( data, res, xhr ) {
            var json = xhr.responseJSON;
            var message = 'ISO rescheduled - ' + json.ids.length + ' new jobs';
            if(json.failed.length) {
                message += ' but ' + json.failed.length + ' failed';
                var details = '';
                for(var i = 0; i != json.failed.length; ++i) {
                    details += '<li><ul><li>' + json.failed[i].error_messages.join('</li><li>') + '</li></ul></li>';
                }
                addFlash('danger', '<strong>' + message + '</strong><ul>' + details + '</li></ul>');
            }
            action_cell.append(message);
        });
        var i = $(this).find('i').removeClass('fa-redo');
        $(this).replaceWith(i);
        return false;
    });
}
