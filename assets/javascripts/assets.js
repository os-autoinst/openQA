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
                          var unitFactor = 1073741824; // one GiB
                          var dataWithUnit;
                          $.each([' GiB', ' MiB', ' KiB', ' byte'], function(index, unit) {
                              if (!unitFactor || data >= unitFactor) {
                                  dataWithUnit = (data / unitFactor) + unit;
                                  return false;
                              }
                              unitFactor >>= 10;
                          });
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
