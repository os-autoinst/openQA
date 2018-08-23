var job_templates_url;
var job_group_id;
var user_is_admin;

function setupJobTemplates(url, id) {
    job_templates_url = url;
    job_group_id = id;
    $.ajax(url + "?group_id=" + id).done(loadJobTemplates);
}

function loadJobTemplates(data) {
    var mediagroups = {};
    var groups = [];
    $.each(data.JobTemplates, function(i, jt) {
        var media = mediagroups[jt.product.group];
        if (!media) {
            groups.push(jt.product.group);
            media = [];
        }
        media.push(jt);
        mediagroups[jt.product.group] = media;
    });
    groups.sort();
    $.each(groups, function(i, group) {
        buildMediumGroup(group, mediagroups[group]);
    });
    var width = alignCols() - 16;
    $('#loading').remove();
    $('.chosen-select').chosen({"width": width + "px"});
    $('a.plus-sign').click(addTestRow);
    $(document).on('change', '.chosen-select', chosenChanged);
}

function highlightChosen(chosen) {
    var container = chosen.parent('td').find('.chosen-container');
    container.fadeTo("fast" , 0.3).fadeTo("fast", 1);
}

function templateRemoved(chosen, deselected) {
    var jid = chosen.find('option[value="' + deselected + '"]').data('jid');
    $.ajax({url: job_templates_url + "/" + jid,
        type: 'DELETE',
        dataType: 'json'}).done(function() { highlightChosen(chosen); });
}

function addFailed(data) {
    // display something without alert
    if (data.hasOwnProperty('responseJSON')) {
        alert(data.responseJSON.error);
    } else {
        alert("unknown error");
    }
}

function addSucceeded(chosen, selected, data) {
    chosen.find('option[value="' + selected + '"]').data('jid', data['id']);
    highlightChosen(chosen);
}

// after a machine was added the select is final
function finalizeTest(tr) {
    var test_select = tr.find('td.name select');
    if (!test_select.length)
        return;

    // disable select and assign the selected ID to the row
    test_select.prop('disabled', true);
    tr.data('test-id', test_select.find('option:selected').data('test-id'));

    // make test unavailable in other selections
    var tbody = tr.parents('tbody');
    presentTests = findPresentTests(tbody);
    tbody.find('td.name select').each(function(index, select) {
        select = $(select);
        if(!select.prop('disabled')) {
            filterTestSelection(select, presentTests);
        }
    });
}

function templateAdded(chosen, selected) {
    var tr = chosen.parents('tr');
    finalizeTest(tr);
    var postData = {
        prio: tr.find('.prio input').val(),
        group_id: job_group_id,
        product_id: chosen.data('product-id'),
        machine_id: chosen.find('option[value="' + selected + '"]').data('machine-id'),
        test_suite_id: tr.data('test-id')
    };

    $.ajax({
        url: job_templates_url,
        type: 'POST',
        dataType: 'json',
        data: postData}).fail(addFailed).done(function(data) { addSucceeded(chosen, selected, data); });
}

function priorityChanged(priorityInput) {
    var tr = priorityInput.parents('tr');

    // just skip if there are no machines added anyways
    var hasMachines = tr.find('td.arch select option:selected').length > 0;
    if (!hasMachines) {
        return;
    }

    $.ajax({
        url: job_templates_url,
        type: 'POST',
        dataType: 'json',
        data: {
            prio: priorityInput.val(),
            prio_only: true,
            group_id: job_group_id,
            test_suite_id: tr.data('test-id'),
        },
    }).fail(addFailed);
}

function chosenChanged(evt, param) {
    if (param.deselected) {
        templateRemoved($(this), param.deselected);
    } else {
        templateAdded($(this), param.selected);
    }
}

function testChanged() {
    var select = $(this);
    var selectedValue = select.find('option:selected').val();
    var noSelection = !selectedValue || selectedValue.length === 0;
    var tr = select.parents('tr');
    var chosens = tr.find('.chosen-select');
    var inputs = tr.find('input');
    chosens.prop('disabled', noSelection).trigger("chosen:updated");
    inputs.prop('disabled', noSelection);
}

function findPresentTests(table) {
    var presentTests = [];
    table.find('td.name').each(function(index, td) {
        var test = td.innerText.trim();
        if(!test) {
            var select = $(td).find('select');
            if(select && select.prop('disabled')) {
                test = select.val();
            }
        }
        if(test) {
            presentTests.push(test);
        }
    });
    return presentTests;
}

function filterTestSelection(select, presentTests) {
    select.find('option').each(function(index, option) {
        if(presentTests.indexOf(option.innerText.trim()) >= 0) {
            $(option).remove();
        }
    });
}

function makePrioCell(prio) {
    // use default priority if no prio passed; also disable the input in this case
    var disableInput = !prio;
    if (!prio) {
        prio = $('#editor-default-priority').data('initial-value');
    }
    if (!prio) {
        prio = 50;
    }

    var td = $('<td class="prio"></td>');
    var prioInput = $('<input type="number"></input>');
    prioInput.val(prio);
    prioInput.change(function() {
        priorityChanged($(this));
    });
    prioInput.prop('disabled', disableInput);
    prioInput.appendTo(td);
    return td;
}

function addTestRow() {
    var table = $(this).parents('table');
    var tbody = table.find('tbody');
    var select = $('#tests-template').clone();
    filterTestSelection(select, findPresentTests(tbody));
    var tr = $('<tr/>').prependTo(tbody);
    var td = $('<td class="name"></td>').appendTo(tr);
    select.appendTo(td);

    select.show();
    select.change(testChanged);
    makePrioCell().appendTo(tr);

    var archnames = table.data('archs');
    var archHeaders = table.find('thead th.arch');
    var archColIndex = 0;
    $.each(archnames, function(archIndex, arch) {
        while (archColIndex < archHeaders.length
            && !archHeaders[archColIndex].innerText.trim()) {
            $('<td class="arch"/>').appendTo(tr);
        ++archColIndex;
            }
            var td = $('<td class="arch"/>').appendTo(tr);
            var select = $('#machines-template').clone().appendTo(td);
            select.attr('id', $(this).parent('table').id + "-" + arch + "-" + 'new');
            select.attr('data-product-id', table.data('product-' + arch));
            select.addClass('chosen-select');
            select.show();
            var width = $('.chosen-container').width();
            select.chosen({"width": width + "px"});
            // wait for the combo box to be selected
            select.prop('disabled', true).trigger("chosen:updated");
    });

    return false;
}

function buildMediumGroup(group, media) {
    var div = $('<div class="jobtemplate-medium"/>').appendTo('#media');
    div.append('<div class="jobtemplate-header">' + group + '</div>');
    var table = $('<table class="table table-striped mediagroup" id="' + group + '"/>').appendTo(div);
    var thead = $('<thead/>').appendTo(table);
    var tr = $('<tr/>').appendTo(thead);
    var tname = tr.append($('<th class="name">Test'
        + (user_is_admin ? ' <a href="#" class="plus-sign"><i class="fa fa-plus"></i></a>' : '')
        + '</th>'));
    tr.append($('<th class="prio">Prio</th>'));
    var archs = {};
    var tests = {};
    var prio = 444;
    $.each(media, function(index, temp) {
        var a = archs[temp.product.arch];
        if (!a)
            a = {};
        if (!a.hasOwnProperty(temp.test_suite.name)) {
            a[temp.test_suite.name] = [];
            table.data('product-' + temp.product.arch, temp.product.id);
            a['_id'] = temp.product.id;
        }
        a[temp.test_suite.name].push(temp);
        archs[temp.product.arch] = a;
        tests[temp.test_suite.name] = { 'prio': temp.prio,
            'id': temp.test_suite.id };
    });
    var archnames = Object.keys(archs).sort();
    table.data('archs', archnames);
    var testnames = Object.keys(tests).sort();
    $.each(archnames, function(index, arch) {
        var a = $('<th class="arch arch_' + arch + '">' + arch + '</th>').appendTo(tr);
    });
    var tbody = $('<tbody/>').appendTo(table);
    $.each(testnames, function(ti, test) {
        var tr = $('<tr class="test_' + test + '"/>').appendTo(tbody);
        tr.data('test-id', tests[test]['id']);
        var shortname = test;
        if (test.length >= 70) {
            shortname = '<span title='+test+'>' + test.substr(0,67) + '…</span>';
        }
        $('<td class="name">' + shortname + '</td>').appendTo(tr);
        makePrioCell(tests[test].prio).appendTo(tr);

        $.each(archnames, function(archIndex, arch) {
            var td = $('<td class="arch"/>').appendTo(tr);
            var select = $('#machines-template').clone().appendTo(td);
            select.attr('id', group + "-" + arch + "-" + test);
            select.attr('data-product-id', archs[arch]['_id']);
            select.addClass('chosen-select');
            if (archs.hasOwnProperty(arch) && archs[arch].hasOwnProperty(test)) {
                $.each(archs[arch][test], function(mi, temp) {
                    var option = select.find("option[value='" + temp.machine.name + "']").prop('selected', true);
                    // remember the id for DELETE
                    option.data('jid', temp.id);
                });
            }
        });
    });
}

function addArchSpacer(table, position, method) {
    $(table).find('thead th.arch').eq(position)[method]('<th class="arch">&nbsp;</th>');
    $(table).find('tbody tr').each(function(){
        $(this).find('td.arch').eq(position)[method]('<td class="arch">&nbsp;</td>');
    });
}

function findHeaderWithAllArchitectures() {
    var headerWithAllArchs = [];
    $("table.mediagroup thead").each(function() {
        var archs = $(this).find('th.arch');
        if (archs.length > headerWithAllArchs.length)
            headerWithAllArchs = archs;
    });
    return headerWithAllArchs;
}

function fillEmptySpace(table, tableHead, headerWithAllArchs) {
    if (tableHead.length < headerWithAllArchs.length) {
        headerWithAllArchs.each(function(i) {
            // Used all ths, fill the rest
            if (tableHead.length == i) {
                for(var j = i; j < headerWithAllArchs.length; j++) {
                    addArchSpacer(table, j-1, 'after');
                }
                return false;
            } else if (this.innerHTML != tableHead.get(i).innerHTML) {
                addArchSpacer(table, i, 'before');
                tableHead = $(table).find('thead th.arch');
            }
        });
    }
}

function alignCols() {
    // Set minimal width
    $('th.name,th.prio').width('0');

    // Find biggest minimal width
    var namewidth = 450;
    $('td.name').each(function(index, test) {
        if ($(this).outerWidth() > namewidth)
            namewidth = $(this).outerWidth();
    });
    namewidth = Math.ceil(namewidth);

    var headerWithAllArchs = findHeaderWithAllArchitectures();

    // Fill empty space
    $("table.mediagroup").each(function(index, table) {
        fillEmptySpace(table, $(this).find('thead th.arch'), headerWithAllArchs);
    });

    // Compute arch width
    var archwidth = $('.jobtemplate-header').outerWidth() - namewidth - $('th.prio').outerWidth();
    archwidth = Math.floor(archwidth / headerWithAllArchs.length) - 1;

    $('th.name').outerWidth(namewidth);
    $('th.arch').outerWidth(archwidth);

    return archwidth;
}

function toggleEdit() {
    $('#properties').toggle(250);
}

function showSubmitResults(form, result) {
    form.find('.buttons').show();
    form.find('.properties-progress-indication').hide();
    form.find('.properties-status').html(result);
}

function submitProperties(form) {
    var editorForm = $(form);
    editorForm.find('.buttons').hide();
    editorForm.find('.progress-indication').show();
    $.ajax({
        url: editorForm.data('put-url'),
           method: 'PUT',
           data: editorForm.serialize(),
           success: function() {
               showSubmitResults(editorForm, '<i class="fas fa-save"></i> Changes applied');

               // show new name
               var newJobName = $('#editor-name').val();
               $('#job-group-name').text(newJobName);
               document.title = document.title.substr(0, 17) + newJobName;
               // update initial value for default priority (used when adding new job template)
               var defaultPropertyInput = $('#editor-default-priority');
               defaultPropertyInput.data('initial-value', defaultPropertyInput.val());
           },
           error: function(xhr, ajaxOptions, thrownError) {
               showSubmitResults(editorForm, '<i class="fas fa-trash"></i> Unable to apply changes');
           }
    });

    return false;
}
