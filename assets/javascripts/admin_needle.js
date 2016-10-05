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
            { "targets": 1,
                "render": function ( data, type, row ) {
                    if (type === 'display') {
                        return "<input type='checkbox'> <span data-id='" +
                        row['id'] + "'>" + data + "</span>";
                    } else
                        return data;
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
        var todelete = 0;
        var ul = $('<ul/>');
        $('input:checked').each(function(index) {
            var li = $('<li/>');
            var span = $(this).parent('td').find('span');
            li.html(span.html());
            li.data('id', span.data('id'));
            todelete += 1;
            ul.append(li);
        });
        if (todelete > 0) {
            $('#confirm_delete .modal-body').html(ul);
            $('#confirm_delete').modal();
        }
    });
    $('#really_delete').click(function() {
        var ids = [];
        $('#confirm_delete .modal-body ul li').each(function(index) {
            ids.push(parseInt($(this).data('id')));
        });
        // delete requests don't support data in the body
        var url = $('#confirm_delete').data('delete-url');
        if (ids.length) {
            url += "?";
            $.each(ids, function(index) { url += 'id=' + ids[index] + '&'; });
        }
        $.ajax({ url: url,
            type: 'DELETE',
            success: reloadNeedlesTable
        });
        return false;
    });

    function reloadNeedlesTable() {
        table.ajax.url(ajaxUrl());
        table.ajax.reload(function() { $('#confirm_delete').modal('hide'); } );
    }
    $('#last_seen_filter').change(reloadNeedlesTable);
    $('#last_match_filter').change(reloadNeedlesTable);
}
