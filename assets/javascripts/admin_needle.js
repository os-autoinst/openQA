function setupAdminNeedles () {
  function ajaxUrl () {
    const url = $('#needles').data('ajax-url');
    let lastMatch = $('#last_match_filter').val();
    let lastSeen = $('#last_seen_filter').val();
    if (lastMatch === 'custom') {
      lastMatch = $('#sel_custom_last_match').val() + $('#last_date_match').val();
    }
    if (lastSeen === 'custom') {
      lastSeen = $('#sel_custom_last_seen').val() + $('#last_date_seen').val();
    }
    return url + '?last_match=' + encodeURIComponent(lastMatch) + '&last_seen=' + encodeURIComponent(lastSeen);
  }

  const table = $('#needles').DataTable({
    ajax: ajaxUrl(),
    deferRender: true,
    columns: [
      { data: 'directory' },
      { data: 'filename' },
      { data: 'last_seen' },
      { data: 'last_match' }
    ],
    processing: true,
    serverSide: true,
    order: [
      [0, 'asc'],
      [1, 'asc']
    ],
    columnDefs: [{
      targets: [2, 3],
      className: 'time',
      render: function (data, type, row) {
        if (type === 'display' && data != 'never') {
          let ri = 'last_seen_link';
          if (data == row.last_match) { ri = 'last_match_link'; }
          return "<a href='" + row[ri] + "'>" + jQuery.timeago(new Date(data)) + '</a>';
        } else {
          return data;
        }
      }
    }, {
      targets: 1,
      render: function (data, type, row) {
        if (type === 'display') {
          return '<input type="checkbox" id="input-' + row.id + '"> <label data-id="' +
                        row.id + '" for="input-' + row.id + '">' + data + '</label>';
        } else {
          return data;
        }
      }
    }]
  });

  $('#select_all').click(function () {
    $('input').prop('checked', true);
  });
  $('#unselect_all').click(function () {
    $('input').prop('checked', false);
  });
  $('#delete_all').click(function () {
    $('#deletion-question').show();
    $('#deletion-ongoing').hide();
    $('#deletion-finished').hide();
    $('#failed-needles').empty();
    $('#outstanding-needles').empty();
    $('#really_delete').show();
    $('#close_delete').show();
    $('#x_delete').show();
    $('#abort_delete').hide();

    const ids = [];
    $('input:checked').each(function (index) {
      const li = $('<li/>');
      const label = $(this).parent('td').find('label');
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

  $('#really_delete').click(function () {
    return startDeletion($(this).data('ids'));
  });

  $('#abort_delete').click(function () {
    $('#outstanding-needles').data('aborted', true);
  });

  function startDeletion (ids) {
    const outstandingList = $('#outstanding-needles');
    const failedList = $('#failed-needles');
    const deletionProgressElement = $('#deletion-progress');
    const url = $('#confirm_delete').data('delete-url') + '?id=';

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
    $('#confirm_delete').animate({ scrollTop: 0 }, 'fast');

    // define function to delete a bunch of needles at once
    // note: Deleting all needles at once could lead to timeouts and the progress could not be tracked at all.
    const needlesToDeleteAtOnce = 5;
    var deleteBunchOfNeedles = function () {
      // handle all needles being deleted (or at least attempted to be deleted)
      if (outstandingList.data('aborted') || ids.length <= 0) {
        reloadNeedlesTable();
        $('#deletion-ongoing').hide();
        $('#abort_delete').hide();
        $('#deletion-finished').show();
        $('#close_delete').show();
        $('#x_delete').show();
        if (ids.length) {
          // allow to continue deleting outstanding needles after abort
          $('#really_delete').show();
        }
        return true;
      }

      // update progress
      deletionProgressElement.text(ids.length);

      // determine the next needle IDs to delete
      const nextIDs = ids.splice(0, needlesToDeleteAtOnce);

      // define function to handle single error affecting all deletions (e.g. GRU task TTL exceeded)
      const handleSingleError = function (singleError) {
        $.each(nextIDs, function (index, id) {
          const errorElement = $('<li></li>');
          errorElement.append($('#deletion-item-' + id).text());
          errorElement.append($('<br>'));
          errorElement.append(singleError);
          failedList.append(errorElement);
          $('#deletion-item-' + id).remove();
        });
        deleteBunchOfNeedles();
      };

      $.ajax({
        url: url + nextIDs.join('&id='),
        type: 'DELETE',
        success: function (response) {
          // add error affecting all deletions
          const singleError = response.error;
          if (singleError) {
            return handleSingleError(singleError);
          }

          // add individual error messages
          if (response.errors) {
            $.each(response.errors, function (index, error) {
              const errorElement = $('<li></li>');
              let errorContext = error.display_name;
              if (!errorContext) {
                errorContext = $('#deletion-item-' + error.id).text();
              }
              if (errorContext) {
                errorElement.append(errorContext);
                errorElement.append($('<br>'));
              }
              errorElement.append(error.message);
              failedList.append(errorElement);
            });
          }

          // delete needles from outstanding list
          $.each(nextIDs, function (index, id) {
            $('#deletion-item-' + id).remove();
          });

          deleteBunchOfNeedles();
        },
        error: function (xhr, ajaxOptions, thrownError) {
          handleSingleError(thrownError);
        }
      });

      return true;
    };

    deleteBunchOfNeedles();
    return true;
  }

  function reloadNeedlesTable (response) {
    table.ajax.url(ajaxUrl());
    table.ajax.reload();
  }

  $('#last_seen_filter').change(function () {
    if ($('#last_seen_filter').val() === 'custom') {
      $('#custom_last_seen').show();
    } else {
      $('#custom_last_seen').hide();
      reloadNeedlesTable();
    }
  });
  $('#last_match_filter').change(function () {
    if ($('#last_match_filter').val() === 'custom') {
      $('#custom_last_match').show();
    } else {
      $('#custom_last_match').hide();
      reloadNeedlesTable();
    }
  });
  $('#btn_custom_last_seen').click(reloadNeedlesTable);
  $('#btn_custom_last_match').click(reloadNeedlesTable);
  $('#custom_last_match').toggle($('#last_match_filter').val() === 'custom');
  $('#custom_last_seen').toggle($('#last_seen_filter').val() === 'custom');
}
