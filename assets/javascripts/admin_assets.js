/* jshint multistr: true */

function setupAdminAssets() {
  // determine params for AJAX queries
  const pageQueryParams = parseQueryParams();
  const ajaxQueryParams = {};
  const forceRefreshParams = pageQueryParams.force_refresh;
  if (forceRefreshParams && forceRefreshParams.length > 0) {
    ajaxQueryParams.force_refresh = forceRefreshParams[0];
  }

  const addAssetGroupLinks = function (container, groupIds, pickedId, path) {
    Object.values(groupIds).forEach(function (groupIdString) {
      const groupId = parseInt(groupIdString);
      var className = 'not-picked';
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
        const errorMsg =
          'Unable to request asset status: ' +
          (response && response.error ? response.error : thrown) +
          ' <a class="btn btn-primary" href="javascript: reloadAssetsTable();">Retry</a>';
        addFlash('danger', errorMsg);
        $('#assets-by-group-loading').hide();
        $('#assets-status').text('failed to load');
      }
    },
    columns: [{data: 'name'}, {data: 'max_job'}, {data: 'size'}, {data: 'groups'}],
    columnDefs: [
      {
        targets: 0,
        render: function (data, type, row) {
          if (type !== 'display') {
            return data;
          }
          return (
            data +
            '<a href="#" onclick="deleteAsset(' +
            row.id +
            ');"><i class="action fa fa-fw fa-times-circle-o" title="Delete asset from disk"></i></a>'
          );
        }
      },
      {
        targets: 1,
        render: function (data, type, row) {
          if (type !== 'display') {
            return data;
          }
          if (!data) {
            return 'none';
          }
          return '<a href="' + urlWithBase('/tests/' + data) + '">' + data + '</a>';
        }
      },
      {
        targets: 2,
        render: function (data, type, row) {
          if (type !== 'display') {
            return data;
          }
          if (data === '') {
            return 'unknown';
          }
          var dataWithUnit = renderDataSize(data);
          if (dataWithUnit) {
            return dataWithUnit;
          }
          return data;
        }
      },
      {
        targets: 3,
        render: function (data, type, row) {
          var groupIds = Object.keys(data).sort();
          var parentGroupIds = Object.keys(row.parents).sort();
          if (type !== 'display') {
            return groupIds.concat(parentGroupIds).join(',');
          }
          var links = [];
          addAssetGroupLinks(links, groupIds, row.picked_into, '/group_overview/');
          addAssetGroupLinks(links, parentGroupIds, row.picked_into_parent_id, '/parent_group_overview/');
          return links.length ? links.join(' ') : 'none';
        }
      }
    ],
    order: [[1, 'desc']]
  });

  // apply search parameter
  const searchParams = pageQueryParams.search;
  if (searchParams && searchParams.length > 0) {
    window.assetsTable.search(searchParams[0]).draw();
  }
}

function reloadAssetsTable() {
  $('#assets-by-group-loading').show();
  $('#assets-status').text('loading');
  $('#flash-messages div.alert').remove();
  window.assetsTable.ajax.reload();
}

function deleteAsset(assetId) {
  fetchWithCSRF(urlWithBase(`/api/v1/assets/${assetId}`), {method: 'DELETE'})
    .then(response => {
      // not checking for status code as 404 case also returns proper json
      return response.json();
    })
    .then(response => {
      if (response.error) throw response.error;
      addFlash(
        'info',
        "The asset was deleted successfully. The asset table's contents are cached." +
          'Hence the removal is not immediately visible. To update the view use the "Trigger asset cleanup" button.' +
          'Note that this is an expensive operation which might take a while.'
      );
    })
    .catch(error => {
      console.error(error);
      addFlash('danger', `Error deleting asset: ${error}`);
    });
}

function triggerAssetCleanup(form) {
  fetchWithCSRF(form.action, {method: form.method})
    .then(response => {
      return response
        .json()
        .then(json => {
          // Attach the parsed JSON to the response object for further use
          return {response, json};
        })
        .catch(() => {
          // If parsing fails, handle it as a non-JSON response
          throw `Server returned ${response.status}: ${response.statusText}`;
        });
    })
    .then(({response, json}) => {
      if (!response.ok) throw `Server returned ${response.status}: ${response.statusText}<br>${json.error || ''}`;
      if (json.error) throw json.error;
      return json;
    })
    .then(response => {
      addFlash(
        'info',
        `Asset cleanup has been triggered. Open the <a href="/minion/jobs?task=limit_assets">Minion dashboard</a> to keep track of the task (gru_id #${response.gru_id}).`
      );
    })
    .catch(error => {
      console.error(error);
      addFlash('danger', `Unable to trigger the asset cleanup: ${error}`);
    });
}

function showLastAssetStatusUpdate(assetStatus) {
  if (assetStatus.last_update) {
    $('#assets-status').html('last update: ' + renderTimeAgo(assetStatus.last_update, 'display'));
  }
}

function makeQualifiedGroupIdForAsset(assetInfo) {
  var parentGroupOfAsset = assetInfo.picked_into_parent_id;
  if (parentGroupOfAsset !== undefined) {
    return 'parent-group-' + parentGroupOfAsset;
  }
  return 'group-' + assetInfo.picked_into;
}

function makeAssetsByGroup(assetStatus) {
  var assetsByGroupHeading = $('#assets-by-group-heading');
  var assetsByGroupList = $('#assets-by-group');
  var totalSize = 0;
  var jobGroups = assetStatus.groups;
  var parentGroups = assetStatus.parents;
  var assets = assetStatus.data;

  $('#assets-by-group-loading').hide();

  // make the asset list for the particular groups
  var assetsByGroup = {};
  assets
    .sort(function (b, a) {
      return a.name.localeCompare(b.name);
    })
    .forEach(function (asset) {
      if (!asset.size || asset.picked_into === undefined) {
        return;
      }

      // make the ul element but don't populate the li elements already
      var qualifiedGroupId = makeQualifiedGroupIdForAsset(asset);
      var assetUl = assetsByGroup[qualifiedGroupId];
      if (!assetUl) {
        assetsByGroup[qualifiedGroupId] = assetUl = $('<ul></ul>');
        assetUl.assets = [];

        // add method lazy-initialize the ul element
        assetUl.populate = function () {
          this.assets.forEach(function (asset) {
            var assetLi = $('<li></li>');
            assetLi.text(asset.name);
            assetLi.append('<span>' + renderDataSize(asset.size) + '</span>');
            assetUl.append(assetLi);
          });
        };
      }
      assetUl.assets.push(asset);
    });

  // add li element for each group, sorted by used asset size and group name
  Object.values(parentGroups)
    .concat(Object.values(jobGroups))
    .sort(function (b, a) {
      if (a.picked < b.picked) {
        return -1;
      } else if (b.picked < a.picked) {
        return 1;
      }
      return a.group.localeCompare(b.group);
    })
    .forEach(function (groupInfo) {
      if (!groupInfo.picked) {
        return;
      }

      var groupId = groupInfo.id !== null ? groupInfo.id : 0;
      var parents = groupInfo.parents;
      var isParent = groupInfo.parent_id === undefined; // parentless job groups have parent_id set to null
      var groupLi = $('<li></li>');
      var qualifiedGroupId = isParent ? 'parent-group-' + groupId : 'group-' + groupId;
      var checkboxId = qualifiedGroupId + '-checkbox';

      // add input for expanding/collapsing
      var groupCheckbox = $('<input id="' + checkboxId + '" type="checkbox"></input>');
      groupLi.append(groupCheckbox);
      var label = $('<label for="' + checkboxId + '">' + groupInfo.group + '</label>');
      groupLi.append(label);

      // add configure button
      if (window.isAdmin && groupId !== null && groupId !== undefined && groupInfo.group !== 'Untracked') {
        var path = isParent ? '/admin/edit_parent_group/' + groupId : '/admin/job_templates/' + groupId;
        groupLi.append('<a href="' + path + '"><i class="fa fa-wrench" title="Configure"></i></a>');
      }

      // add size
      var size = groupInfo.picked;
      totalSize += size;
      var sizeString = renderDataSize(size);
      if (groupInfo.size_limit_gb) {
        sizeString += ' / ' + groupInfo.size_limit_gb + ' GiB';
      }
      groupLi.append('<span>' + sizeString + '</span>');

      // setup lazy-loading for list of assets
      var assetUl = assetsByGroup[qualifiedGroupId];
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
