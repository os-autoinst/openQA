function setup_asset_table()
{
    $('#assets').DataTable(
        {
            "columnDefs": [
                { targets: 3,
                  "render": function ( data, type, row ) {
                      if (type === 'display') {
                          return jQuery.timeago(data + "Z");
                      } else
                          return data;
                  }
                }
            ],
            "order": [[3, 'desc']]
        }
    );
}
