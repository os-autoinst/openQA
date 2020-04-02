var audit_url;
var ajax_url;

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
        { data: 'id' },
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
            visible: false
        },
        {
            targets: 1,
            render: function ( data, type, row ) {
                if (type === 'display')
                    // I want to have a link to events for cases when one wants to share interesing event
                    return '<a href="' + audit_url + '?eventid=' + row.id + '" title=' + data + '>' + jQuery.timeago(data + " UTC") + '</a>';
                else
                    return data;
            }
        },
        {
            targets: 3,
            visible: false
        },
        {
            targets: 5,
            width: "70%",
            render: function ( data, type, row ) {
                if (type === 'display' && data) {
                    var parsed_data;
                    try {
                        parsed_data = JSON.stringify(JSON.parse(data), null, 2);
                    } catch (e) {
                        parsed_data = data;
                    }
                    return '<span class="audit_event_data" title="' + htmlEscape(parsed_data) + '">' + htmlEscape(parsed_data) + '</span>';
                }
                else {
                    return data;
                }
            }
        },
    ],
    });
}

var scheduledProductsTable;

function dataForLink(link) {
    return scheduledProductsTable.row($(link).closest('tr')).data();
}

function showScheduledProductSettings(link) {
    var rowData = dataForLink(link);
    var settings = JSON.parse(rowData[10]);
    var table = $('<table/>').addClass('table table-striped');
    Object.keys(settings).forEach(function(key, index) {
        table.append($('<tr/>').append($('<td/>').text(key)).append($('<td/>').text(settings[key])));
    });

    var modalDialog = $('#scheduled-product-modal');
    modalDialog.find('.modal-title').text('Scheduled product settings');
    modalDialog.find('.modal-body').empty().append(table);
    modalDialog.modal();
}

function showScheduledProductResults(link) {
    var url = $(link).data('url');
    $.get(url, undefined, function(data, textStatus, xhr) {
        var results = data.results;
        var element;
        if (results) {
            element = $('<pre></pre>');
            element.text(JSON.stringify(results, undefined, 4));
        } else {
            element = $('<p></p>');
            element.text('No results available.');
        }

        var modalDialog = $('#scheduled-product-modal');
        modalDialog.find('.modal-title').text('Scheduled product results');
        modalDialog.find('.modal-body').empty().append(element);
        modalDialog.modal();

    }).fail(function(response) {
        var responseText = response.responseText;
        if (responseText) {
            addFlash('danger', 'Unable to query results: ' + responseText);
        } else {
            addFlash('danger', 'Unable to query results.');
        }
    });
}

function rescheduleProduct(link) {
    if (!window.confirm('Do you really want to reschedule all jobs for the product?')) {
        return;
    }

    var url = $(link).data('url');
    $.post(url, undefined, function() {
        addFlash('info', 'Re-scheduling the product has been triggered. A new scheduled product should appear when refreshing the page.');
    }).fail(function(response) {
        var responseText = response.responseText;
        if (responseText) {
            addFlash('danger', 'Unable to trigger re-scheduling: ' + responseText);
        } else {
            addFlash('danger', 'Unable to trigger re-scheduling.');
        }
    });
}

function loadProductLogTable()
{
    scheduledProductsTable = $('#product_log_table').DataTable({
        lengthMenu: [10, 25, 50],
        order: [[1, 'desc']],
        columnDefs: [
        {
            targets: 0,
            visible: false,
            searchable: false,
        },
        {
            targets: 1,
            render: function (data, type, row) {
                if (type === 'display') {
                    return jQuery.timeago(data + 'Z');
                } else {
                    return data;
                }
            }
        },
        {
            targets: 10,
            visible: false,
            searchable: true,
        },
        ]
    });
}
