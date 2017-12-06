function setup_asset_table()
{
    $('#assets').DataTable(
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
