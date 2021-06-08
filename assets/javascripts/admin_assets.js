/* jshint multistr: true */

function setupAdminAssets () {
  // determine params for AJAX queries
  const pageQueryParams = parseQueryParams();
  const ajaxQueryParams = {};
  const paramValues = pageQueryParams.force_refresh;
  if (paramValues && paramValues.length > 0) {
    ajaxQueryParams.force_refresh = paramValues[0];
  }

  const addAssetGroupLinks = function (container, groupIds, pickedId, path) {
    Object.values(groupIds).forEach(function (groupIdString) {
      const groupId = parseInt(groupIdString);
      let className = 'not-picked';
      if (pickedId === groupId) {
        className = 'picked-group';
      } else if (pickedId === 0) {
        className = 'to-be-removed';
      }
      container.push('<a class="' + className + '" href="' + path + groupId + '">' + groupId + '</a>');
    });
  };

  // setup data table
  const assetsTable = $('#assets');
  window.assetsTable = assetsTable.DataTable({
    ajax: {
      url: assetsTable.data('status-url'),
      data: ajaxQueryParams,
      dataSrc: function (json) {
        showLastAssetStatusUpdate(json);
        makeAssetsByGroup(json);
        return json.data;
      },
      error: function (xhr, error, thrown) {
        const response = xhr.responseJSON;
        const errorMsg = 'Unable to request asset status: ' +
                    (response && response.error ? response.error : thrown) +
                    ' <a class="btn btn-primary" href="javascript: reloadAssetsTable();">Retry</a>';
        addFlash('danger', errorMsg);
        $('#assets-by-group-loading').hide();
        $('#assets-status').text('failed to load');
      }
    },
    columns: [
      { data: 'name' },
      { data: 'max_job' },
      { data: 'size' },
      { data: 'groups' }
    ],
    columnDefs: [{
      targets: 0,
      render: function (data, type, row) {
        if (type !== 'display') {
          return data;
        }
        return data + '<a href="#" onclick="deleteAsset(' + row.id + ');">\
                                <i class="action far fa-fw fa-times-circle" title="Delete asset"></i>\
                                </a>';
      }
    }, {
      targets: 1,
      render: function (data, type, row) {
        if (type !== 'display') {
          return data;
        }
        if (!data) {
          return 'none';
        }
        return '<a href="/tests/' + data + '">' + data + '</a>';
      }
    }, {
      targets: 2,
      render: function (data, type, row) {
        if (type !== 'display') {
          return data;
        }
        if (data === '') {
          return 'unknown';
        }
        const dataWithUnit = renderDataSize(data);
        if (dataWithUnit) {
          return dataWithUnit;
        }
        return data;
      }
    }, {
      targets: 3,
      render: function (data, type, row) {
        const groupIds = Object.keys(data).sort();
        const parentGroupIds = Object.keys(row.parents).sort();
        if (type !== 'display') {
          return groupIds.concat(parentGroupIds).join(',');
        }
        const links = [];
        addAssetGroupLinks(links, groupIds, row.picked_into, '/group_overview/');
        addAssetGroupLinks(links, parentGroupIds, row.picked_into_parent_id, '/parent_group_overview/');
        return links.length ? links.join(' ') : 'none';
      }
    }],
    order: [
      [1, 'desc']
    ]
  });
}

function reloadAssetsTable () {
  $('#assets-by-group-loading').show();
  $('#assets-status').text('loading');
  $('#flash-messages div.alert').remove();
  window.assetsTable.ajax.reload();
}

function deleteAsset (assetId) {
  $.ajax({
    url: '/api/v1/assets/' + assetId,
    method: 'DELETE',
    dataType: 'json',
    success: function () {
      addFlash('info', 'The asset was deleted successfully. The asset table\'s contents are cached. Hence the removal is not immediately visible. To update the view use the "Trigger asset cleanup" button. Note that this is an expensive operation which might take a while.');
    },
    error: function (xhr, ajaxOptions, thrownError) {
      const error_message = xhr.responseJSON.error;
      addFlash('danger', error_message);
    }
  });
}

function triggerAssetCleanup (form) {
  $.ajax({
    url: form.action,
    method: form.method,
    success: function () {
      addFlash('info', 'Asset cleanup has been triggered. Open the <a href="/minion">Minion dashboard</a> to keep track of the task.');
    },
    error: function (xhr, ajaxOptions, thrownError) {
      addFlash('danger', 'Unable to trigger the asset cleanup: ' + thrownError);
    }
  });
}

function showLastAssetStatusUpdate (assetStatus) {
  if (assetStatus.last_update) {
    $('#assets-status').html('last update: ' + renderTimeAgo(assetStatus.last_update, 'display'));
  }
}

function makeQualifiedGroupIdForAsset (assetInfo) {
  const parentGroupOfAsset = assetInfo.picked_into_parent_id;
  if (parentGroupOfAsset !== undefined) {
    return 'parent-group-' + parentGroupOfAsset;
  }
  return 'group-' + assetInfo.picked_into;
}

function makeAssetsByGroup (assetStatus) {
  const assetsByGroupHeading = $('#assets-by-group-heading');
  const assetsByGroupList = $('#assets-by-group');
  let totalSize = 0;
  const jobGroups = assetStatus.groups;
  const parentGroups = assetStatus.parents;
  const assets = assetStatus.data;

  $('#assets-by-group-loading').hide();

  // make the asset list for the particular groups
  const assetsByGroup = {};
  assets.sort(function (b, a) {
    return a.name.localeCompare(b.name);
  }).forEach(function (asset) {
    if (!asset.size || asset.picked_into === undefined) {
      return;
    }

    // make the ul element but don't populate the li elements already
    const qualifiedGroupId = makeQualifiedGroupIdForAsset(asset);
    let assetUl = assetsByGroup[qualifiedGroupId];
    if (!assetUl) {
      assetsByGroup[qualifiedGroupId] = assetUl = $('<ul></ul>');
      assetUl.assets = [];

      // add method lazy-initialize the ul element
      assetUl.populate = function () {
        this.assets.forEach(function (asset) {
          const assetLi = $('<li></li>');
          assetLi.text(asset.name);
          assetLi.append('<span>' + renderDataSize(asset.size) + '</span>');
          assetUl.append(assetLi);
        });
      };
    }
    assetUl.assets.push(asset);
  });

  // add li element for each group, sorted by used asset size and group name
  Object.values(parentGroups).concat(Object.values(jobGroups)).sort(function (b, a) {
    if (a.picked < b.picked) {
      return -1;
    } else if (b.picked < a.picked) {
      return 1;
    }
    return a.group.localeCompare(b.group);
  }).forEach(function (groupInfo) {
    if (!groupInfo.picked) {
      return;
    }

    const groupId = groupInfo.id !== null ? groupInfo.id : 0;
    const parents = groupInfo.parents;
    const isParent = groupInfo.parent_id === undefined; // parentless job groups have parent_id set to null
    const groupLi = $('<li></li>');
    const qualifiedGroupId = isParent ? ('parent-group-' + groupId) : ('group-' + groupId);
    const checkboxId = qualifiedGroupId + '-checkbox';

    // add input for expanding/collapsing
    const groupCheckbox = $('<input id="' + checkboxId + '" type="checkbox"></input>');
    groupLi.append(groupCheckbox);
    const label = $('<label for="' + checkboxId + '">' + groupInfo.group + '</label>');
    groupLi.append(label);

    // add configure button
    if (window.isAdmin && groupId !== null && groupId !== undefined && groupInfo.group !== 'Untracked') {
      const path = isParent ? ('/admin/edit_parent_group/' + groupId) : ('/admin/job_templates/' + groupId);
      groupLi.append('<a href="' + path + '"><i class="fa fa-wrench" title="Configure"></i></a>');
    }

    // add size
    const size = groupInfo.picked;
    totalSize += size;
    let sizeString = renderDataSize(size);
    if (groupInfo.size_limit_gb) {
      sizeString += ' / ' + groupInfo.size_limit_gb + ' GiB';
    }
    groupLi.append('<span>' + sizeString + '</span>');

    // setup lazy-loading for list of assets
    const assetUl = assetsByGroup[qualifiedGroupId];
    if (assetUl) {
      groupCheckbox.change(function () {
        if (assetUl.initialized) {
          return;
        }
        assetUl.populate();
        groupLi.append(assetUl);
        assetUl.initialized = true;
      });
    }

    assetsByGroupList.append(groupLi);
  });

  assetsByGroupHeading.text('Assets by group (total ' + renderDataSize(totalSize) + ')');
}
