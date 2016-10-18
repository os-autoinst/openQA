function setupAdminNeedles() {
    function ajaxUrl() {
        var url = $('#needles').data('ajax-url');
        return url + "?last_match=" + $('#last_match_filter').val() + "&last_seen=" + $('#last_seen_filter').val();
    }

    var table = $('#needles').DataTable(
        { "ajax": ajaxUrl(),
            deferRender: true,
            "columns": [
            { "data": "directory" },
            { "data": "filename" },
            { "data": "last_seen" },
            { "data": "last_match" }
            ],
            "processing": true,
            "serverSide": true,
            "order": [[0, "asc"], [1, "asc"]],
            "columnDefs": [
            {  "targets": [2,3],
                "className": "time",
                "render": function (data, type, row) {
                    if (type === 'display' && data != 'never') {
                        var ri = 'last_seen_link';
                        if (data == row['last_match'])
                            ri = 'last_match_link';
                        return "<a href='" + row[ri] + "'>" + jQuery.timeago(new Date(data)) + "</a>";
                    } else {
                        return data;
                    }
                }
            },
            { "targets": 1,
                "render": function (data, type, row) {
                    if (type === 'display') {
                        return '<input type="checkbox" id="input-' + row.id + '"> <label data-id="'
                            + row.id + '" for="input-' + row.id + '">' + data + '</label>';
                    } else {
                        return data;
                    }
                }
            }
            ]
        });

    $('#select_all').click(function() {
        $('input').prop('checked', true);
    });
    $('#unselect_all').click(function() {
        $('input').prop('checked', false);
    });
    $('#delete_all').click(function() {
        $('#deletion-question').show();
        $('#deletion-ongoing').hide();
        $('#deletion-finished').hide();
        $('#failed-needles').empty();
        $('#outstanding-needles').empty();
        $('#really_delete').show();
        $('#close_delete').show();
        $('#x_delete').show();
        $('#abort_delete').hide();

        var ids = [];
        $('input:checked').each(function(index) {
            var li = $('<li/>');
            var label = $(this).parent('td').find('label');
            li.html(label.html());
            li.attr('id', 'deletion-item-' + label.data('id'));
            ids.push(label.data('id'));
            $('#outstanding-needles').append(li);
        });
        if (ids.length > 0) {
            $('#really_delete').data('ids', ids);
            $('#confirm_delete').modal();
        }
    });

    $('#really_delete').click(function() {
        return startDeletion($(this).data('ids'));
    });

    $('#abort_delete').click(function() {
        $('#outstanding-needles').data('aborted', true);
    });

    function startDeletion(ids) {
        var outstandingList = $('#outstanding-needles');
        var failedList = $('#failed-needles');
        var deletionProgressElement = $('#deletion-progress');
        var url = $('#confirm_delete').data('delete-url') + '?id=';

        // hide/show elements
        $('#deletion-question').hide();
        $('#deletion-ongoing').show();
        $('#really_delete').hide();
        $('#close_delete').hide();
        $('#x_delete').hide();
        $('#abort_delete').show();

        // ensure previous 'aborted'-flag is cleared
        $('#outstanding-needles').data('aborted', false);

        // failed needles will be displayed at the top first, so it makes sense
        // to scroll there
        $('#confirm_delete').animate({scrollTop: 0}, 'fast');

        // delete needle by needle
        var deleteNext = function() {
            if(!outstandingList.data('aborted') && ids.length > 0) {
                // update progress
                deletionProgressElement.text(ids.length);

                // delete next ID
                var id = ids.shift();
                $.ajax({
                    url: url + id,
                    type: 'DELETE',
                    success: function(response) {
                        $.each(response.errors, function(index, error) {
                            var errorElement = $('<li></li>');
                            errorElement.append(error.display_name);
                            errorElement.append($('<br>'));
                            errorElement.append(error.message);
                            failedList.append(errorElement);
                        });
                        $('#deletion-item-' + id).remove();
                        deleteNext();
                    },
                    error: function(xhr, ajaxOptions, thrownError) {
                        var errorElement = $('<li></li>');
                        errorElement.append($('#deletion-item-' + id).text());
                        errorElement.append($('<br>'));
                        errorElement.append(thrownError);
                        failedList.append(errorElement);
                        $('#deletion-item-' + id).remove();
                        deleteNext();
                    }
                });
            } else {
                // all needles deleted (at least tried to)
                reloadNeedlesTable();
                $('#deletion-ongoing').hide();
                $('#abort_delete').hide();
                $('#deletion-finished').show();
                $('#close_delete').show();
                $('#x_delete').show();
                if(ids.length) {
                    // allow to continue deleting outstanding needles after abort
                    $('#really_delete').show();
                }
            }
            return true;
        };

        deleteNext();
        return true;
    }

    function reloadNeedlesTable(response) {
        table.ajax.url(ajaxUrl());
        table.ajax.reload();
    }

    $('#last_seen_filter').change(reloadNeedlesTable);
    $('#last_match_filter').change(reloadNeedlesTable);
}
