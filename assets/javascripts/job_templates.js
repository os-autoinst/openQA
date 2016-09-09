var job_templates_url;
var job_group_id;

function setupJobTemplates(url, id) {
    job_templates_url = url;
    job_group_id = id;
    $.ajax(url + "?group_id=" + id).done(loadJobTemplates);
}

function loadJobTemplates(data) {
    var mediagroups = {};
    var groups = [];
    $.each(data.JobTemplates, function(i, jt) {
	var medias = mediagroups[jt.product.group];
	if (!medias) {
	    groups.push(jt.product.group);
	    medias = [];
	}
	medias.push(jt);
	mediagroups[jt.product.group] = medias;
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
    if (!test_select)
	return;
    test_select.prop('disabled', true);
    tr.data('test-id', test_select.find('option:selected').data('test-id'));
}

function templateAdded(chosen, selected) {
    var temp = {};
    var tr = chosen.parents('tr');
    finalizeTest(tr);
    temp['prio'] = tr.find('.prio').text();
    temp['group_id'] = job_group_id;
    temp['product_id'] = chosen.data('product-id');
    temp['machine_id'] = chosen.find('option[value="' + selected + '"]').data('machine-id');
    temp['test_suite_id'] = tr.data('test-id');

    $.ajax({url: job_templates_url,
	    type: 'POST',
	    dataType: 'json',
	    data: temp}).fail(addFailed).done(function(data) { addSucceeded(chosen, selected, data); });
}
    
function chosenChanged(evt, param) {
    if (param.deselected) {
	templateRemoved($(this), param.deselected);
    } else {
	templateAdded($(this), param.selected);
    }
}

function testChanged() {
    var selected = $(this).find('option:selected').val();
    var chosens = $(this).parents('tr').find('.chosen-select');
    chosens.prop('disabled', selected == '').trigger("chosen:updated");
}

function addTestRow() {
    var table = $(this).parents('table');
    var tbody = table.find('tbody');
    var tr = $('<tr/>').prependTo(tbody);
    var td = $('<td class="name"></td>').appendTo(tr);
    var select = $('#tests-template').clone().appendTo(td);
    select.show();
    select.change(testChanged);
    $('<td class="prio">50</td>').appendTo(tr);

    var archnames = table.data('archs');
    $.each(archnames, function(ai, arch) {
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
    var tname = tr.append($('<th class="name">Test <a href="#" class="plus-sign"><i class="fa fa-plus"></i></a></th>'));
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
		shortname = '<span title='+test+'>' + test.substr(0,67) + '...</span>';
	}
	$('<td class="name">' + shortname + '</td>').appendTo(tr);
	$('<td class="prio">' + tests[test]['prio'] + '</td>').appendTo(tr);
	
	$.each(archnames, function(ai, arch) {
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

function alignCols() {
	// Set minimal width
	$('th.name').width('0');
	$('th.prio').width('0');
	
	// Find biggest minimal width
	var namewidth = 450;
	$('td.name').each(function(index, test) {
		if ($(this).outerWidth() > namewidth) 
			namewidth = $(this).outerWidth();
	});
	namewidth = Math.ceil(namewidth);

    // Find header with all architectures
    var ths_all = [];
    $("table.mediagroup thead").each(function() {
    	var archs = $(this).find('th.arch');
    	if (archs.length > ths_all.length)
    		ths_all = archs;
    });

	// Fill empty space
	$("table.mediagroup").each(function(index, table) {
		var ths = $(this).find('thead th.arch');
		if (ths.length < ths_all.length) {
			ths_all.each(function(i) {
				// Used all ths, fill the rest
				if (ths.length == i) {
					for(var j = i; j < ths_all.length; j++) {
						addArchSpacer(table, j-1, 'after');
					}
					return false;
				} else if (this.innerHTML != ths.get(i).innerHTML) {
					addArchSpacer(table, i, 'before');
					ths = $(table).find('thead th.arch');
				}
			});
		}
	});

	// Compute arch width
	var archwidth = $('.jobtemplate-header').outerWidth() - namewidth - $('th.prio').outerWidth();
	archwidth = Math.floor(archwidth / ths_all.length) - 1;

	$('th.name').outerWidth(namewidth);
	$('th.arch').outerWidth(archwidth);

	return archwidth;
}

