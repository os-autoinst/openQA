function updateTextArea(textArea) {
  textArea.style.height = 'auto';
  textArea.style.height = Math.min(textArea.scrollHeight + 5, 300) + 'px';
}

function extendAdminTableSearch(searchTerm) {
  window.adminTable.search('((' + window.adminTable.search() + ')|(' + searchTerm + '))');
}

var newRowId = 'new row';

function showAdminTableRow(row) {
  var adminTable = window.adminTable;

  // set pagination to the page containing the new row
  var pageInfo = adminTable.page.info();
  var rowPosition = adminTable.rows({search: 'applied'})[0].indexOf(row.index());
  if (rowPosition < 0) {
    // extend the search if the row to be shown would otherwise be filtered out
    var rowData = row.data();
    extendAdminTableSearch(!rowData.id ? newRowId : rowData.id);
    rowPosition = adminTable.rows({search: 'applied'})[0].indexOf(row.index());
  }
  if (rowPosition < 0) {
    // handle case when updating the regex does not work
    addFlash('info', 'The added/updated row has been filtered out.');
    return;
  }
  if (rowPosition < pageInfo.start || rowPosition >= pageInfo.end) {
    adminTable.page(Math.floor(rowPosition / adminTable.page.len())).draw(false);
  }

  // scroll to the new row
  const rowNode = row.node();
  window.scrollTo({top: rowNode.getBoundingClientRect().top + window.scrollY, behavior: 'smooth'});
}

function addAdminTableRow() {
  var adminTable = window.adminTable;

  // add new row
  var newRow = adminTable.row.add(adminTable.emptyRow);
  var newRowIndex = newRow.index();
  adminTable.rowData[newRowIndex] = Object.assign({isEditing: true}, adminTable.emptyRow);
  newRow.invalidate().draw();

  showAdminTableRow(newRow);
}

function isEditingAdminTableRow(meta) {
  var rowData = window.adminTable.rowData;
  var rowIndex = meta.row;
  return rowIndex < rowData.length && rowData[rowIndex].isEditing;
}

function setEditingAdminTableRow(tdElement, editing, submitted) {
  // get the data table row for the tdElement
  var adminTable = window.adminTable;
  var rowData = adminTable.rowData;
  var row = adminTable.row(tdElement.parentElement);
  if (!row) {
    addFlash('danger', 'Internal error: invalid table row/cell specified');
    return;
  }

  // get the buffered row data updated from editor elements before submitting and set the 'isEditing' flag there
  var rowIndex = row.index();
  if (rowIndex < rowData.length) {
    var data = rowData[rowIndex];
    data.isEditing = editing;

    // pass the buffered row data from editor elements to the data table
    // note: This applies submitted changes or restores initial values when editing is cancelled by the user.
    if (submitted) {
      row.data(data);
    }
  }

  // invalidate the table row not resetting the pagination (false parameter to draw())
  row.invalidate().draw(false);
}

function refreshAdminTableRow(tdElement) {
  window.adminTable.row(tdElement.parentElement).invalidate().draw();
}

function adminTableApiUrl() {
  return urlWithBase(document.getElementById('admintable_api_url').value);
}

function handleAdminTableSubmit(tdElement, response, id) {
  // leave editing mode
  setEditingAdminTableRow(tdElement, false, true);

  // query affected row again so changes applied by the server (removing invalid chars from settings keys) are visible
  fetch(adminTableApiUrl() + '/' + id)
    .then(response => {
      return response.json();
    })
    .then(response => {
      if (response.error) throw response.error;
      var rowData = response[Object.keys(response)[0]];
      if (rowData) {
        rowData = rowData[0];
      }
      if (!rowData) {
        addFlash('danger', 'Internal error: server replied invalid row data.');
        return;
      }

      var adminTable = window.adminTable;
      var row = adminTable.row(tdElement.parentElement);
      var rowIndex = row.index();
      if (rowIndex >= adminTable.rowData.length) {
        return;
      }
      row.data((adminTable.rowData[rowIndex] = rowData)).draw(false);
      showAdminTableRow(row);
    })
    .catch(error => {
      addFlash('danger', error);
    });
}

function getAdminTableRowData(trElement, dataToSubmit, internalRowData) {
  const table = trElement.closest('table');
  const tableHeadings = table.querySelectorAll('th');
  Array.from(trElement.cells).forEach(function (td) {
    const th = tableHeadings[td.cellIndex];
    const name = th.textContent.trim().toLowerCase();
    let value;
    if (th.classList.contains('col_value')) {
      value = td.querySelector('input').value;
      if (name === 'distri') {
        value = value.toLowerCase();
      }
      if (dataToSubmit) {
        dataToSubmit[name] = value;
      }
      if (internalRowData) {
        internalRowData[name] = value;
      }
    } else if (th.classList.contains('col_settings_list')) {
      const settingsToSubmit = {};
      const internalRowSettings = [];
      td.querySelectorAll('.key-value-pairs').forEach(function (textarea) {
        textarea.value.split('\n').forEach(function (line, index) {
          // ignore empty lines
          if (line.length === 0) {
            return;
          }
          // determine key and value
          var equationSignIndex = line.indexOf('=');
          if (equationSignIndex < 1) {
            if (dataToSubmit) {
              // fail if settings should be submitted
              throw {
                type: 'invalid line',
                lineNo: index + 1,
                text: line
              };
            } else {
              // ignore error if only saving the row internally
              equationSignIndex = line.length;
            }
          }
          var key = line.substr(0, equationSignIndex);
          var val = line.substr(equationSignIndex + 1);
          settingsToSubmit[key] = val;
          internalRowSettings.push({key: key, value: val});
        });
      });
      if (dataToSubmit) {
        dataToSubmit.settings = settingsToSubmit;
      }
      if (internalRowData) {
        internalRowData.settings = internalRowSettings;
      }
    } else if (th.classList.contains('col_description')) {
      const descriptionEl = td.querySelector('.description');
      value = descriptionEl ? descriptionEl.value : '';
      if (dataToSubmit) {
        dataToSubmit[name] = value;
      }
      if (internalRowData) {
        internalRowData[name] = value;
      }
    }
  });
}

function submitAdminTableRow(tdElement, id) {
  var adminTable = window.adminTable;
  var rowIndex = adminTable.row(tdElement.parentElement).index();
  if (rowIndex === undefined) {
    addFlash('danger', 'Internal error: invalid table cell specified');
    return;
  }
  var rowData = adminTable.rowData[rowIndex];
  if (!rowData) {
    addFlash('danger', 'Internal error: row data is missing');
    return;
  }

  var dataToSubmit = {};
  try {
    getAdminTableRowData(tdElement.parentElement, dataToSubmit, rowData);
  } catch (e) {
    if (e.type !== 'invalid line') {
      throw e;
    }
    addFlash('danger', 'Line ' + e.lineNo + ' of settings is invalid: ' + e.text);
    return;
  }

  const url = adminTableApiUrl();
  if (id) {
    // update
    fetchWithCSRF(url + '/' + id, {
      method: 'PUT',
      body: JSON.stringify(dataToSubmit),
      headers: {'Content-Type': 'application/json'}
    })
      .then(response => {
        return response.json();
      })
      .then(response => {
        if (response.error) throw response.error;
        handleAdminTableSubmit(tdElement, response, id);
      })
      .catch(error => {
        addFlash('danger', error);
      });
  } else {
    // create new
    fetchWithCSRF(url, {
      method: 'POST',
      body: JSON.stringify(dataToSubmit),
      headers: {'Content-Type': 'application/json'}
    })
      .then(response => {
        return response.json();
      })
      .then(response => {
        if (response.error) throw response.error;
        handleAdminTableSubmit(tdElement, response, response.id);
      })
      .catch(error => {
        addFlash('danger', error);
      });
  }
}

function removeAdminTableRow(tdElement) {
  var adminTable = window.adminTable;
  var row = adminTable.row(tdElement.parentElement);
  var rowIndex = row.index();
  if (rowIndex !== undefined && rowIndex < adminTable.rowData.length) {
    adminTable.rowData.splice(rowIndex, 1);
  }
  row.remove().draw();
}

function deleteTableRow(tdElement, id) {
  if (!confirm('Really delete?')) {
    return;
  }

  // delete unsubmitted row
  if (!id) {
    removeAdminTableRow(tdElement);
    return;
  }

  fetchWithCSRF(adminTableApiUrl() + '/' + id, {method: 'DELETE'})
    .then(response => {
      return response.json();
    })
    .then(response => {
      if (response.error) throw response.error;
      removeAdminTableRow(tdElement);
    })
    .catch(error => {
      addFlash('danger', error);
    });
}

function renderAdminTableValue(data, type, row, meta) {
  if (type !== 'display') {
    return data ? data : '';
  }
  if (isEditingAdminTableRow(meta)) {
    return '<input type="text" value="' + htmlEscape(data) + '"/>';
  }
  return htmlEscape(data);
}

function renderAdminTableSettingsList(data, type, row, meta) {
  var plainText = type !== 'display';
  var edit = isEditingAdminTableRow(meta);
  var result = '';
  if (edit) {
    result += '<textarea class="key-value-pairs" oninput="updateTextArea(this);">';
  }
  for (var j = 0; j < data.length; j++) {
    var keyValuePair = data[j];
    var key = htmlEscape(keyValuePair.key);
    var value = htmlEscape(keyValuePair.value);
    if (edit || plainText) {
      result += key + '=' + value + '\n';
    } else {
      result +=
        '<span class="key-value-pair"><span class="key">' +
        key +
        '</span>=<span class="value">' +
        value +
        '</span></span><br/>';
    }
  }
  if (edit) {
    result += '</textarea>';
  }
  return result;
}

function renderAdminTableDescription(data, type, row, meta) {
  if (type !== 'display') {
    return data ? data : '';
  }
  if (isEditingAdminTableRow(meta)) {
    return '<textarea class="description">' + htmlEscape(data) + '</textarea>';
  }
  return htmlEscape(data);
}

function renderAdminTableActions(data, type, row, meta) {
  if (type !== 'display') {
    return data ? data : newRowId;
  }
  if (isEditingAdminTableRow(meta)) {
    return renderEditableAdminTableActions(data, type, row, meta);
  }
  if (!window.isAdmin) {
    return '';
  }
  return '<button type="submit" class="btn" alt="Edit" title="Edit" onclick="setEditingAdminTableRow(this.parentElement, true, false);"><i class="fa fa-edit"></i></button>';
}

function renderEditableAdminTableActions(data, type, row, meta) {
  if (type !== 'display') {
    return data ? data : newRowId;
  }
  if (!window.isAdmin) {
    return '';
  }
  if (data) {
    // show submit/cancel/delete buttons while editing existing row
    return (
      '<button type="submit" class="btn" alt="Update" title="Update" onclick="submitAdminTableRow(this.parentElement, ' +
      data +
      ');"><i class="fa fa-save"></i></button><button type="submit" class="btn" alt="Cancel" title="Cancel" onclick="setEditingAdminTableRow(this.parentElement, false, true);"><i class="fa fa-undo"></i></button><button type="submit" class="btn" alt="Delete" title="Delete" onclick="deleteTableRow(this.parentElement, ' +
      data +
      ');"><i class="fa fa-trash-o"></i></button>'
    );
  } else {
    // show submit/cancel button while adding new row
    return '<button type="submit" class="btn" alt="Add" title="Add" onclick="submitAdminTableRow(this.parentElement);"><i class="fa fa-save"></i></button><button type="submit" class="btn" alt="Cancel" title="Cancel" onclick="deleteTableRow(this.parentElement);"><i class="fa fa-undo"></i></button>';
  }
}

function setupAdminTable(isAdmin) {
  // adjust sorting so empty strings come last
  Object.assign(DataTable.ext.type.order, {
    'empty-string-last-asc': function (str1, str2) {
      if (str1 === '') {
        return 1;
      }
      if (str2 === '') {
        return -1;
      }
      return str1 < str2 ? -1 : str1 > str2 ? 1 : 0;
    },
    'empty-string-last-desc': function (str1, str2) {
      if (str1 === '') {
        return 1;
      }
      if (str2 === '') {
        return -1;
      }
      return str1 < str2 ? 1 : str1 > str2 ? -1 : 0;
    }
  });

  // read columns from empty HTML table rendered by the server
  var emptyRow = {};
  var columns = [];
  var columnDefs = [];
  document.querySelectorAll('.admintable thead th').forEach(function (th) {
    // add column
    var columnName;
    if (th.classList.contains('col_action')) {
      columnName = 'id';
    } else {
      columnName = th.textContent.trim().toLowerCase();
    }
    columns.push({data: columnName});

    // add column definition to customize rendering and sorting and add template for empty row
    var columnDef = {
      targets: columns.length - 1,
      type: 'empty-string-last'
    };
    if (th.classList.contains('col_value')) {
      columnDef.render = renderAdminTableValue;
      emptyRow[columnName] = '';
    } else if (th.classList.contains('col_settings')) {
      columnDef.render = renderAdminTableSettings;
      emptyRow.settings = {};
    } else if (th.classList.contains('col_settings_list')) {
      columnDef.render = renderAdminTableSettingsList;
      columnDef.orderable = false;
      emptyRow.settings = [];
    } else if (th.classList.contains('col_description')) {
      columnDef.render = renderAdminTableDescription;
      emptyRow.description = '';
    } else if (th.classList.contains('col_action')) {
      columnDef.render = renderAdminTableActions;
      columnDef.orderable = false;
    } else {
      emptyRow[columnName] = '';
    }
    columnDefs.push(columnDef);
  });

  // setup admin table
  const url = adminTableApiUrl();
  const tableEl = document.querySelector('.admintable');
  const dataTable = new DataTable(tableEl, {
    order: [[0, 'asc']],
    ajax: {
      url: url,
      dataSrc: function (json) {
        // assume the first "key" contains the data
        var rowData = json[Object.keys(json)[0]];
        if (!rowData) {
          addFlash('danger', 'Internal error: server response misses table data');
          return (dataTable.rowData = []);
        }
        return (dataTable.rowData = rowData);
      }
    },
    columns: columns,
    columnDefs: columnDefs,
    search: {
      regex: true
    }
  });
  dataTable.rowData = [];
  dataTable.emptyRow = emptyRow;

  // take keywords from the URL
  const params = new URLSearchParams(document.location.search.substring(1));
  const keywords = params.get('q');
  if (keywords) {
    dataTable.search(keywords);
  }

  // save the current editor values before redraw so they survive using filtering/sorting/pagination
  dataTable.on('preDraw', function () {
    var rowData = dataTable.rowData;
    tableEl.querySelectorAll('tbody tr').forEach(function (tr) {
      var row = dataTable.row(tr);
      var rowIndex = row.index();
      if (rowIndex === undefined || rowIndex >= rowData.length) {
        return;
      }
      var data = Object.assign({}, rowData[rowIndex]);
      if (!data.isEditing) {
        return;
      }
      getAdminTableRowData(tr, undefined, data);
      row.data(data);
    });
  });

  // make the height of text areas fit its contents
  dataTable.on('draw', function () {
    tableEl.querySelectorAll('textarea').forEach(updateTextArea);
  });

  // set/update page-global state (there can only be one admin table at a page anyways)
  window.isAdmin = isAdmin;
  window.adminTable = dataTable;

  // prevent sorting when help popover on table heading is clicked
  tableEl.querySelectorAll('th .help_popover').forEach(function (popover) {
    popover.addEventListener('click', function (event) {
      event.stopPropagation();
    });
  });
}
