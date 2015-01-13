
function table_row (data, table, edit)
{
    var html = "<tr>";
    
    table.find('th').each (function() {
        var th = $(this);
        var name = th.text().trim();
        
        if (th.hasClass("col_value")) {
            var value = data[name];
            if (edit) {
                html +=
                '<td>' +
                     '<input size="5" type="text" value="' + value + '"/>' +
                 '</td>';
            }
            else {
                html += '<td>' + value + '</td>';
            }
        }
        else if (th.hasClass("col_settings")) {
            var value = '';
            for (var j = 0; j < data['settings'].length; j++) {
                if (name === data['settings'][j]['key']) {
                    value = data['settings'][j]['value'];
                    break;
                }
            }
            if (edit) {
                html +=
                '<td>' +
                     '<input size="5" type="text" value="' + value + '"/>' +
                 '</td>';
            }
            else {
                html += '<td>' + value + '</td>';
            }
        }
        else if (th.hasClass("col_settings_list")) {
            html += '<td><ul>';
            for (var j = 0; j < data['settings'].length; j++) {
                var k = data['settings'][j]['key'];

                var col = false;
                table.find('th.col_settings').each (function() {
                    if ($(this).text().trim() == k) col = true;
                });

                if (col) continue; /* skip vars in extra columns */

                var v = data['settings'][j]['value'];
                if (edit) {
                    html += '<span class="key-value-pair"><span class="key">' + k + '</span>=<input size="5" type="text" class="value" value="' + v + '"/></span><br/>'
                }
                else {
                    html += '<span class="key-value-pair"><span class="key">' + k + '</span>=<span class="value">' + v + '</span></span><br/>';
                }
            }
            if (edit) {
                 html += '<span class="key-value-pair"><input size="5" class="key" type="text"/>=<input size="5" type="text" class="value"/></span><br/>';
            }
            html += '</ul></td>';
        } else if (th.hasClass("col_action")) {
            if (edit) {
                html +=
                '<td>' +
                     '<input id="done" value="done" onclick="submit_table_row_button( this, ' + data['id'] + ');" type="button"/>' +
                     '<input id="cancel" value="cancel" onclick="refresh_table_row_button( this, ' + data['id'] + ' , false );" type="button"/>' +
                 '</td>';
            }
            else {
                html +=
                '<td>' +
                     '<input id="edit" value="edit" onclick="refresh_table_row_button( this, ' + data['id'] + ' , true );" type="button"/>' +
                '</td>';
            }
        }
    });
    html += "</tr>";

    return html;
}

function refresh_table_row (tr, id, edit)
{
    var url = $("#admintable_api_url").val();

    $.ajax({
        url: url + "/" + id,
        type: "GET",
        dataType: 'json',
        success: function(resp) {
//            alert(JSON.stringify());
            var db_table = Object.keys(resp)[0];
            var json_row = resp[db_table][0];
            var table = $(tr).closest('table');
            var new_tr_html = table_row(json_row, table, edit);
            $(tr).replaceWith(new_tr_html);
        },
        error: function(request, status, error) {
           alert(error);
        }

    });
}

function submit_table_row(tr, id)
{
    var data = {};
    $(tr).find('td').each (function() {
        var th = $(this).closest('table').find('th').eq( this.cellIndex );
        
        var name = th.text().trim();
        
        if (th.hasClass("col_value")) {
            var value = $(this).find("input").val();
            data[name] = value;
        }
        else if (th.hasClass("col_settings")) {
            var value = $(this).find("input").val();
            if (value) {
                data["settings[" + name + "]"] = value;
            }
        }
        else if (th.hasClass("col_settings_list")) {
            $(this).find('.key-value-pair').each (function() {
                var key;
                var k = $(this).find('span.key');
                if (k.length) {
                    key = k.text().trim();
                }
                else {
                    k = $(this).find('input.key');
                    if (k.length) key = k.val();
                }
                if (key) {
                    var value = $(this).find('input.value').val();
                    if (value) {
                        data["settings[" + key + "]"] = value;
                    }
                }
            });
        }
    });
    
//    alert(JSON.stringify(data));
    var url = $("#admintable_api_url").val();

    $.ajax({
        url: url + "/" + id,
        type: "POST",
        dataType: 'json',
        data: data,
        headers: {
            'X-HTTP-Method-Override': 'PUT'
        },
        success: function(resp) {
            refresh_table_row(tr, id, false);
        },
        error: function(request, status, error) {
           alert(error);
        }

    });
}

function refresh_table_row_button (button, id, edit)
{
    var tr = $(button).closest('tr')[0];
    refresh_table_row(tr, id, edit);
}

function submit_table_row_button (button, id)
{
    var tr = $(button).closest('tr')[0];
    submit_table_row(tr, id);
}

function populate_admin_table ()
{
    var url = $("#admintable_api_url").val();
    if (url) {
        $.ajax({
            url: url,
            type: "GET",
            dataType: 'json',
            success: function(resp) {
                var db_table = Object.keys(resp)[0];
                var json_table = resp[db_table];
                var table = $('.admintable');
                var html = '';
                for (var i = 0; i < json_table.length; i++) {
                    html += table_row(json_table[i], table, false);
                }
                table.find('tbody').html(html);
            },
            error: function(request, status, error) {
               alert(error);
            }
        });
    }
}

jQuery(populate_admin_table);
