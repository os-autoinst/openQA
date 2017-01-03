function htmlEscape(str) {
    return String(str)
    .replace(/&/g, '&amp;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;');
}

function updateTextArea(textArea) {
    textArea.style.height = 'auto';
    textArea.style.height = Math.min(textArea.scrollHeight + 5, 300) + 'px';
}

function table_row (data, table, edit, is_admin)
{
    var html = "<tr>";

    table.find('th').each (function() {
        var th = $(this);
        var name = th.text().trim().toLowerCase();

        if (th.hasClass("col_value")) {
            var value = '';
            if (data[name]) value = htmlEscape(data[name]);
            if (edit) {
                html +=
                '<td class="editable">' +
                     '<input type="text" value="' + value + '"/>' +
                 '</td>';
            }
            else {
                html += '<td>' + value + '</td>';
            }
        }
        else if (th.hasClass("col_settings")) {
            var value = '';
            if (data['settings']) {
                for (var j = 0; j < data['settings'].length; j++) {
                    if (name === data['settings'][j]['key']) {
                        value = htmlEscape(data['settings'][j]['value']);
                        break;
                    }
                }
            }
            if (edit) {
                html +=
                '<td class="editable">' +
                     '<input type="text" value="' + value + '"/>' +
                 '</td>';
            }
            else {
                html += '<td>' + value + '</td>';
            }
        }
        else if (th.hasClass("col_settings_list")) {
            if (edit) {
                html += '<td class="editable">';
            }
            else {
                html += '<td>';
            }
            if (edit) {
                html += '<textarea class="key-value-pairs" oninput="updateTextArea(this);">';
            }
            if (data['settings']) {
                for (var j = 0; j < data['settings'].length; j++) {
                    var k = htmlEscape(data['settings'][j]['key']);

                    var col = false;
                    table.find('th.col_settings').each (function() {
                        if ($(this).text().trim() == k) col = true;
                    });

                    if (col) continue; /* skip vars in extra columns */

                    var v = htmlEscape(data['settings'][j]['value']);
                    if (edit) {
                        html += k + '=' + v + '\n';
                    }
                    else {
                        html += '<span class="key-value-pair"><span class="key">' + k + '</span>=<span class="value">' + v + '</span></span><br/>';
                    }
                }
            }
            if (edit) {
                html += '</textarea>';
            }
            html += '</td>';
        } else if (th.hasClass("col_description")) {
            var description = '';
            if (data[name]) description = htmlEscape(data[name]);
            if (edit) {
                html +=
                '<td class="editable">' +
                     '<textarea class="description">' + description + '</textarea>' +
                 '</td>';
            }
            else {
                html += '<td>' + description + '</td>';
            }
        } else if (th.hasClass("col_action")) {
            html += '<td>';
            if (edit) {
                if (data['id']) {
                    // edit existing
                    html +=
                         '<button type="submit" class="btn" alt="Update" title="Update" onclick="submit_table_row_button( this, ' + data['id'] + ');"><i class="fa fa-floppy-o"></i></button>' +
                         '<button type="submit" class="btn" alt="Cancel" title="Cancel" onclick="refresh_table_row_button( this, ' + data['id'] + ' , false);"><i class="fa fa-undo"></i></button>' +
                         '<button type="submit" class="btn" alt="Delete" title="Delete" onclick="delete_table_row_button( this, ' + data['id'] + ');"><i class="fa fa-trash"></i></button>';
                }
                else {
                    // add new
                    html +=
                         '<button type="submit" class="btn" alt="Add" title="Add" onclick="submit_table_row_button( this );"><i class="fa fa-floppy-o"></i></button>' +
                         '<button type="submit" class="btn" alt="Cancel" title="Cancel" onclick="delete_table_row_button( this );"><i class="fa fa-undo"></i></button>';
                }
            }
            else if (is_admin) {
                html +=
                     '<button type="submit" class="btn" alt="Edit" title="Edit" onclick="refresh_table_row_button( this, ' + data['id'] + ' , true);"><i class="fa fa-pencil-square-o"></i></button>';
            }
            html += '</td>';
        }
    });
    html += "</tr>";

    return html;
}

function admintable_api_error(request, status, error) {
   if (request['responseJSON']['error']) {
       error += ': ' + request['responseJSON']['error'];
   }
   alert(error);
}

function refresh_table_row (tr, id, edit)
{
    var url = $("#admintable_api_url").val();

    $.ajax({
        url: url + "/" + id,
        type: "GET",
        dataType: 'json',
        success: function(resp) {
            var db_table = Object.keys(resp)[0];
            var json_row = resp[db_table][0];
            var table = $(tr).closest('table');
            $(tr).replaceWith(table_row(json_row, table, edit, 1));
            table.find('textarea').each(function() {
                updateTextArea(this);
            })
        },
        error: admintable_api_error
    });
}

function submit_table_row(tr, id)
{
    try {
        var data = {};
        $(tr).find('td').each (function() {
            var th = $(this).closest('table').find('th').eq( this.cellIndex );

            var name = th.text().trim().toLowerCase();

            if (th.hasClass("col_value")) {
                var value = $(this).find("input").val();
                // distri name must be lowercase
                if (name == 'distri') {
                    value = value.toLowerCase();
                }
                data[name] = value;
            }
            else if (th.hasClass("col_settings")) {
                var value = $(this).find("input").val();
                if (value) {
                    data["settings[" + name + "]"] = value;
                }
            }
            else if (th.hasClass("col_settings_list")) {
                data.settings = {};
                $(this).find('.key-value-pairs').each (function() {
                    $.each($(this).val().split('\n'), function(index) {
                        // ignore empty lines
                        if (this.length === 0) {
                            return;
                        }
                        // determine key and value
                        var equationSignIndex = this.indexOf('=');
                        if (equationSignIndex < 1) {
                            throw {
                                type: 'invalid line',
                                lineNo: index + 1,
                                text: this
                            };
                        }
                        var key = this.substr(0, equationSignIndex);
                        var value = this.substr(equationSignIndex + 1);
                        data.settings[key] = value;
                    });
                });
            }
            else if (th.hasClass("col_description")) {
                var value = $(this).find('.description').val();
                data[name] = value;
            }

        });

        var url = $("#admintable_api_url").val();
        if (id) {
            // update
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
                error: admintable_api_error
            });
        }
        else {
            // create new
            $.ajax({
                url: url,
                type: "POST",
                dataType: 'json',
                data: data,
                success: function(resp) {
                    id = resp['id'];
                    refresh_table_row(tr, id, false);
                },
                error: admintable_api_error
            });
        }
    }
    catch(e) {
        if(e.type !== 'invalid line') {
            throw e;
        }
        window.alert('Line ' + e.lineNo + ' of settings is invalid: ' + e.text);
    }
}


function delete_table_row (tr, id)
{
    if (id) {
        if (!confirm("Really delete?")) return;

        var url = $("#admintable_api_url").val();

        $.ajax({
            url: url + "/" + id,
            type: "DELETE",
            dataType: 'json',
            success: function(resp) {
                $(tr).remove();
            },
            error: admintable_api_error
        });
    }
    else {
        // just remove the table row
        $(tr).remove();
    }
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

function delete_table_row_button (button, id)
{
    var tr = $(button).closest('tr')[0];
    delete_table_row(tr, id);
}

function add_table_row_button ()
{
    var table = $('.admintable');
    var html = table_row({}, table, true);
    table.find('tr:last').after(html);
}

function populate_admin_table (is_admin)
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
                    html += table_row(json_table[i], table, false, is_admin);
                }
                table.find('tbody').html(html);
		// a really stupid datatable
                table.DataTable( {
                    "paging" : false,
                    "lengthChange": false,
                    "ordering": false
                } );
	    },
            error: admintable_api_error
        });
    }
}

