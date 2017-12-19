function setup_asset_table() {
    $('#assets, #untracked-assets').DataTable(
        {
            columnDefs: [
                { targets: 3,
                  render: function(data, type, row) {
                      if (type === 'display') {
                          return jQuery.timeago(data + "Z");
                      }
                      return data;
                  }
                },
                { targets: 4,
                  render: function(data, type, row) {
                      if (type === 'display') {
                          if (data === '') {
                              return 'unknown';
                          }
                          var dataWithUnit = renderDataSize(data);
                          if (dataWithUnit) {
                            return dataWithUnit;
                          }
                      }
                      return data;
                  }
                }
            ],
            order: [[3, 'desc']]
        }
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
