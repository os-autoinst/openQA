function setupAdminAssets() {
    // determine params for AJAX queries
    var pageQueryParams = parseQueryParams();
    var ajaxQueryParams = {};
    var paramValues = pageQueryParams.force_refresh;
    if (paramValues && paramValues.length > 0) {
        ajaxQueryParams.force_refresh = paramValues[0];
    }

    // setup data table
    var assetsTable = $('#assets');
    assetsTable.DataTable({
            ajax: {
                url: assetsTable.data('status-url'),
                data: ajaxQueryParams,
                dataSrc: function(json) {
                    makeAssetsByGroup(json);
                    return json.data;
                }
            },
            columns: [
                { data: "name" },
                { data: "max_job" },
                { data: "size" },
                { data: "groups" },
            ],
            columnDefs: [
                {
                    targets: 0,
                    render: function(data, type, row) {
                        if (type !== 'display') {
                            return data;
                        }
                        return data + '<a href="#" onclick="deleteAsset(' + row.id + ');">\
                                <i class="action far fa-fw fa-times-circle" title="Delete asset"></i>\
                                </a>';
                    }
                },
                {
                    targets: 1,
                    render: function(data, type, row) {
                        if (type !== 'display') {
                            return data;
                        }
                        if (!data) {
                            return 'none';
                        }
                        return '<a href="/tests/' + data + '">' + data + '</a>';
                    }
                },
                {
                    targets: 2,
                    render: function(data, type, row) {
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
                    render: function(data, type, row) {
                        var groupIds = Object.keys(data).sort();
                        if (type !== 'display') {
                            return groupIds.join(',');
                        }
                        var pickedInto = row.picked_into;
                        for (var groupIndex in groupIds) {
                            var groupId = parseInt(groupIds[groupIndex]);
                            var className = 'not-picked';
                            if (pickedInto === groupId) {
                                className = 'picked-group';
                            } else if (pickedInto === 0) {
                                className = 'to-be-removed';
                            }
                            groupIds[groupIndex] = '<a class="' + className +
                                '" href="/group_overview/' + groupId + '">' +
                                groupId + '</a>';
                        }
                        return groupIds.length ? groupIds.join(' ') : 'none';
                    }
                },

            ],
            order: [[1, 'desc']],
        },
    );
}

function deleteAsset(assetId) {
    $.ajax({
        url: '/api/v1/assets/' + assetId,
        method: 'DELETE',
        success: function() {
            $('#asset_' + assetId).remove();
        },
        error: function(xhr, ajaxOptions, thrownError) {
            window.alert('The asset couldn\'t be deleted: ' + thrownError);
        }
    });
}

function makeAssetsByGroup(assetStatus) {
    var assetsByGroupHeading = $('#assets-by-group-heading');
    var assetsByGroupList = $('#assets-by-group');
    var totalSize = 0;
    var groups = assetStatus.groups;
    var assets = assetStatus.data;

    // sort groups
    var groupIds = Object.keys(groups).sort(function(b, a) {
        var a = groups[a], b = groups[b];
        if (a.picked < b.picked) {
            return -1;
        } else if (b.picked < a.picked) {
            return 1;
        }
        return a.group.localeCompare(b.group);
    });

    // make asset lists
    var assetsByGroup = {};
    var assetsSortedByName = assets.sort(function(b, a) {
        return a.name.localeCompare(b.name);
    });
    for (var assetIndex in assetsSortedByName) {
        var asset = assets[assetIndex];
        if (!asset.size || asset.picked_into === undefined) {
            continue;
        }
        var assetUl = assetsByGroup[asset.picked_into];
        if (!assetUl) {
            assetsByGroup[asset.picked_into] = assetUl = $('<ul></ul>');;
        }
        var assetLi = $('<li></li>');
        assetLi.text(asset.name);
        assetLi.append('<span>' + renderDataSize(asset.size) + '</span>');
        assetUl.append(assetLi);
    }

    // add li element for each group
    for (var groupIndex in groupIds) {
        var groupId = parseInt(groupIds[groupIndex]);
        var groupInfo = groups[groupId];
        if (!groupInfo.picked) {
            continue;
        }

        var groupLi = $('<li></li>');

        // add input for expanding/collapsing
        groupLi.append('<input id="group-' + groupId + '-checkbox" type="checkbox"></input>');
        groupLi.append('<label for="group-' + groupId + '-checkbox">' + groupInfo.group + '</label>');

        // add configure button
        if (window.isAdmin && groupId !== undefined) {
            groupLi.append('<a href="/admin/job_templates/' + groupId +
                '"><i class="fa fa-wrench" title="Configure"></i></a>');
        }

        // add size
        var size = groupInfo.picked;
        totalSize += size;
        var sizeString = renderDataSize(size);
        if (groupInfo.size_limit_gb) {
            sizeString += ' / ' + groupInfo.size_limit_gb + ' GiB';
        }
        groupLi.append('<span>' + sizeString + '</span>');

        // add list for assets
        var assetUl = assetsByGroup[groupId];
        if (assetUl) {
            groupLi.append(assetUl);
        }

        assetsByGroupList.append(groupLi);
    }

    assetsByGroupHeading.text('Assets by group (total ' + renderDataSize(totalSize) + ')');
}
