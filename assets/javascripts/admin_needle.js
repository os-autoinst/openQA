function setupAdminNeedles() {
  function ajaxUrl() {
    const needlesEl = document.getElementById('needles');
    if (!needlesEl) return '';
    var url = needlesEl.dataset.ajaxUrl;
    var lastMatch = document.getElementById('last_match_filter').value;
    var lastSeen = document.getElementById('last_seen_filter').value;
    if (lastMatch === 'custom') {
      lastMatch =
        document.getElementById('sel_custom_last_match').value + document.getElementById('last_date_match').value;
    }
    if (lastSeen === 'custom') {
      lastSeen =
        document.getElementById('sel_custom_last_seen').value + document.getElementById('last_date_seen').value;
    }
    return url + '?last_match=' + encodeURIComponent(lastMatch) + '&last_seen=' + encodeURIComponent(lastSeen);
  }

  var table = new DataTable('#needles', {
    ajax: ajaxUrl(),
    deferRender: true,
    columns: [{data: 'directory'}, {data: 'filename'}, {data: 'last_seen'}, {data: 'last_match'}],
    processing: true,
    serverSide: true,
    order: [
      [0, 'asc'],
      [1, 'asc']
    ],
    columnDefs: [
      {
        targets: [2, 3],
        className: 'time',
        render: function (data, type, row) {
          if (type === 'display' && data != 'never') {
            var ri = 'last_seen_link';
            if (data == row['last_match']) ri = 'last_match_link';
            return "<a href='" + row[ri] + "' title='" + data + "Z'>" + window.timeago.format(data) + '</a>';
          } else {
            return data;
          }
        }
      },
      {
        targets: 1,
        render: function (data, type, row) {
          if (type === 'display') {
            return (
              '<input type="checkbox" id="input-' +
              row.id +
              '"> <label data-id="' +
              row.id +
              '" for="input-' +
              row.id +
              '">' +
              data +
              '</label>'
            );
          } else {
            return data;
          }
        }
      }
    ]
  });

  const selectAll = document.getElementById('select_all');
  if (selectAll) {
    selectAll.addEventListener('click', function () {
      document.querySelectorAll('#needles input[type="checkbox"]').forEach(el => (el.checked = true));
    });
  }
  const unselectAll = document.getElementById('unselect_all');
  if (unselectAll) {
    unselectAll.addEventListener('click', function () {
      document.querySelectorAll('#needles input[type="checkbox"]').forEach(el => (el.checked = false));
    });
  }
  const deleteAll = document.getElementById('delete_all');
  if (deleteAll) {
    deleteAll.addEventListener('click', function () {
      const deletionQuestion = document.getElementById('deletion-question');
      if (deletionQuestion) deletionQuestion.style.display = 'block';
      const deletionOngoing = document.getElementById('deletion-ongoing');
      if (deletionOngoing) deletionOngoing.style.display = 'none';
      const deletionFinished = document.getElementById('deletion-finished');
      if (deletionFinished) deletionFinished.style.display = 'none';
      const failedNeedles = document.getElementById('failed-needles');
      if (failedNeedles) failedNeedles.innerHTML = '';
      const outstandingNeedles = document.getElementById('outstanding-needles');
      if (outstandingNeedles) outstandingNeedles.innerHTML = '';
      const reallyDelete = document.getElementById('really_delete');
      if (reallyDelete) reallyDelete.style.display = 'inline-block';
      const closeDelete = document.getElementById('close_delete');
      if (closeDelete) closeDelete.style.display = 'inline-block';
      const xDelete = document.getElementById('x_delete');
      if (xDelete) xDelete.style.display = 'inline-block';
      const abortDelete = document.getElementById('abort_delete');
      if (abortDelete) abortDelete.style.display = 'none';

      var ids = [];
      document.querySelectorAll('#needles input:checked').forEach(function (checkbox) {
        const id = checkbox.id.replace('input-', '');
        const label = document.querySelector('label[for="' + checkbox.id + '"]');
        if (!label) return;
        const li = document.createElement('li');
        li.innerHTML = label.innerHTML;
        li.id = 'deletion-item-' + id;
        ids.push(id);
        if (outstandingNeedles) outstandingNeedles.appendChild(li);
      });
      if (ids.length > 0) {
        if (reallyDelete) reallyDelete.dataset.ids = JSON.stringify(ids);
        new bootstrap.Modal('#confirm_delete').show();
      }
    });
  }

  const reallyDelete = document.getElementById('really_delete');
  if (reallyDelete) {
    reallyDelete.addEventListener('click', function () {
      return startDeletion(JSON.parse(this.dataset.ids));
    });
  }

  const abortDelete = document.getElementById('abort_delete');
  if (abortDelete) {
    abortDelete.addEventListener('click', function () {
      const outstandingNeedles = document.getElementById('outstanding-needles');
      if (outstandingNeedles) outstandingNeedles.dataset.aborted = 'true';
    });
  }

  function startDeletion(ids) {
    const outstandingList = document.getElementById('outstanding-needles');
    const failedList = document.getElementById('failed-needles');
    const deletionProgressElement = document.getElementById('deletion-progress');
    const confirmDeleteModalEl = document.getElementById('confirm_delete');
    const url = confirmDeleteModalEl.dataset.deleteUrl;

    // hide/show elements
    document.getElementById('deletion-question').style.display = 'none';
    document.getElementById('deletion-ongoing').style.display = 'block';
    document.getElementById('really_delete').style.display = 'none';
    document.getElementById('close_delete').style.display = 'none';
    document.getElementById('x_delete').style.display = 'none';
    document.getElementById('abort_delete').style.display = 'inline-block';

    // ensure previous 'aborted'-flag is cleared
    if (outstandingList) outstandingList.dataset.aborted = 'false';

    // failed needles will be displayed at the top first, so it makes sense
    // to scroll there
    confirmDeleteModalEl.scrollTo({top: 0, behavior: 'smooth'});

    // define function to delete a bunch of needles at once
    // note: Deleting all needles at once could lead to timeouts and the progress could not be tracked at all.
    var needlesToDeleteAtOnce = 5;
    var deleteBunchOfNeedles = function () {
      // handle all needles being deleted (or at least attempted to be deleted)
      if (outstandingList.dataset.aborted === 'true' || ids.length <= 0) {
        reloadNeedlesTable();
        document.getElementById('deletion-ongoing').style.display = 'none';
        document.getElementById('abort_delete').style.display = 'none';
        document.getElementById('deletion-finished').style.display = 'block';
        document.getElementById('close_delete').style.display = 'inline-block';
        document.getElementById('x_delete').style.display = 'inline-block';
        if (ids.length) {
          // allow to continue deleting outstanding needles after abort
          document.getElementById('really_delete').style.display = 'inline-block';
        }
        return true;
      }

      // update progress
      if (deletionProgressElement) deletionProgressElement.textContent = ids.length;

      // determine the next needle IDs to delete
      var nextIDs = ids.splice(0, needlesToDeleteAtOnce);

      // define function to handle single error affecting all deletions (e.g. GRU task TTL exceeded)
      var handleSingleError = function (singleError) {
        nextIDs.forEach(function (id) {
          const errorElement = document.createElement('li');
          const item = document.getElementById('deletion-item-' + id);
          if (item) {
            errorElement.append(item.textContent);
            errorElement.append(document.createElement('br'));
            item.remove();
          }
          errorElement.append(singleError);
          if (failedList) failedList.appendChild(errorElement);
        });
        deleteBunchOfNeedles();
      };

      var request = new XMLHttpRequest();
      request.open('DELETE', url, true);
      request.setRequestHeader('X-CSRF-TOKEN', getCSRFToken());
      request.onload = function () {
        // handle non-JSON response (e.g. server error)
        var response;
        try {
          response = JSON.parse(this.responseText);
        } catch (e) {
          return handleSingleError('Server returned ' + this.status + ': ' + this.statusText);
        }

        // add error affecting all deletions
        var singleError = response.error;
        if (singleError) {
          return handleSingleError(singleError);
        }

        // add individual error messages
        if (response.errors) {
          response.errors.forEach(function (error) {
            const errorElement = document.createElement('li');
            var errorContext = error.display_name;
            if (!errorContext) {
              const item = document.getElementById('deletion-item-' + error.id);
              if (item) errorContext = item.textContent;
            }
            if (errorContext) {
              errorElement.append(errorContext);
              errorElement.append(document.createElement('br'));
            }
            errorElement.append(error.message);
            if (failedList) failedList.appendChild(errorElement);
          });
        }

        // delete needles from outstanding list
        nextIDs.forEach(function (id) {
          const item = document.getElementById('deletion-item-' + id);
          if (item) item.remove();
        });

        deleteBunchOfNeedles();
      };
      request.onerror = function () {
        handleSingleError(this.statusText || 'Unknown error');
      };

      const body = new FormData();
      nextIDs.forEach(id => body.append('id', id));
      request.send(body);
    };

    deleteBunchOfNeedles();
  }

  function reloadNeedlesTable(response) {
    table.ajax.url(ajaxUrl());
    table.ajax.reload();
  }

  const lastSeenFilter = document.getElementById('last_seen_filter');
  if (lastSeenFilter) {
    lastSeenFilter.addEventListener('change', function () {
      const customLastSeen = document.getElementById('custom_last_seen');
      if (this.value === 'custom') {
        if (customLastSeen) customLastSeen.style.display = 'block';
      } else {
        if (customLastSeen) customLastSeen.style.display = 'none';
        reloadNeedlesTable();
      }
    });
  }
  const lastMatchFilter = document.getElementById('last_match_filter');
  if (lastMatchFilter) {
    lastMatchFilter.addEventListener('change', function () {
      const customLastMatch = document.getElementById('custom_last_match');
      if (this.value === 'custom') {
        if (customLastMatch) customLastMatch.style.display = 'block';
      } else {
        if (customLastMatch) customLastMatch.style.display = 'none';
        reloadNeedlesTable();
      }
    });
  }
  const btnCustomLastSeen = document.getElementById('btn_custom_last_seen');
  if (btnCustomLastSeen) btnCustomLastSeen.addEventListener('click', reloadNeedlesTable);
  const btnCustomLastMatch = document.getElementById('btn_custom_last_match');
  if (btnCustomLastMatch) btnCustomLastMatch.addEventListener('click', reloadNeedlesTable);

  const customLastMatch = document.getElementById('custom_last_match');
  if (customLastMatch) customLastMatch.style.display = lastMatchFilter.value === 'custom' ? 'block' : 'none';
  const customLastSeen = document.getElementById('custom_last_seen');
  if (customLastSeen) customLastSeen.style.display = lastSeenFilter.value === 'custom' ? 'block' : 'none';
}
