var job_templates_url;
var job_group_id;
var user_is_admin;
var editor;

function setupJobTemplates(url, id) {
  job_templates_url = url;
  job_group_id = id;
  $.ajax(url + '?group_id=' + id).done(loadJobTemplates);
}

function loadJobTemplates(data) {
  var mediagroups = {};
  var groups = [];
  $.each(data.JobTemplates, function (i, jt) {
    var media = mediagroups[jt.product.group];
    if (!media) {
      groups.push(jt.product.group);
      media = [];
    }
    media.push(jt);
    mediagroups[jt.product.group] = media;
  });
  groups.sort();
  $.each(groups, function (i, group) {
    buildMediumGroup(group, mediagroups[group]);
  });
  var width = alignCols() - 16;
  $('#loading').remove();
  $('.chosen-select').chosen({width: width + 'px'});
  $(document).on('change', '.chosen-select', chosenChanged);
}

function highlightChosen(chosen) {
  var container = chosen.parent('td').find('.chosen-container');
  container.fadeTo('fast', 0.3).fadeTo('fast', 1);
}

function templateRemoved(chosen, deselected) {
  var jid = chosen.find('option[value="' + deselected + '"]').data('jid');
  $.ajax({
    url: job_templates_url + '/' + jid,
    type: 'DELETE',
    dataType: 'json'
  })
    .done(function () {
      highlightChosen(chosen);
    })
    .fail(addFailed);
}

function addFailed(data) {
  // display something without alert
  if (Object.prototype.hasOwnProperty.call(data, 'responseJSON')) {
    alert(data.responseJSON.error);
  } else {
    alert('unknown error');
  }
}

function addSucceeded(chosen, selected, data) {
  chosen.find('option[value="' + selected + '"]').data('jid', data['id']);
  highlightChosen(chosen);
}

// after a machine was added the select is final
function finalizeTest(tr) {
  var test_select = tr.find('td.name select');
  if (!test_select.length) return;

  // disable select and assign the selected ID to the row
  test_select.prop('disabled', true);
  tr.data('test-id', test_select.find('option:selected').data('test-id'));

  // make test unavailable in other selections
  var tbody = tr.parents('tbody');
  presentTests = findPresentTests(tbody);
  tbody.find('td.name select').each(function (index, select) {
    select = $(select);
    if (!select.prop('disabled')) {
      filterTestSelection(select, presentTests);
    }
  });
}

function formatPriority(prio) {
  return !prio || prio.length === 0 ? 'inherit' : prio;
}

function templateAdded(chosen, selected) {
  var tr = chosen.parents('tr');
  finalizeTest(tr);
  var postData = {
    prio: formatPriority(tr.find('.prio input').val()),
    group_id: job_group_id,
    product_id: chosen.data('product-id'),
    machine_id: chosen.find('option[value="' + selected + '"]').data('machine-id'),
    test_suite_id: tr.data('test-id')
  };

  $.ajax({
    url: job_templates_url,
    type: 'POST',
    dataType: 'json',
    data: postData
  })
    .fail(addFailed)
    .done(function (data) {
      addSucceeded(chosen, selected, data);
    });
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
      prio: formatPriority(priorityInput.val()),
      prio_only: true,
      group_id: job_group_id,
      test_suite_id: tr.data('test-id')
    }
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
  chosens.prop('disabled', noSelection).trigger('chosen:updated');
  inputs.prop('disabled', noSelection);
}

function findPresentTests(table) {
  var presentTests = [];
  table.find('td.name').each(function (index, td) {
    var test;
    var select = $(td).find('select');
    if (select.length && select.prop('disabled')) {
      test = select.val();
    } else {
      test = td.innerText.trim();
    }
    if (test) {
      presentTests.push(test);
    }
  });
  return presentTests;
}

function filterTestSelection(select, presentTests) {
  select.find('option').each(function (index, option) {
    if (presentTests.indexOf(option.innerText.trim()) >= 0) {
      $(option).remove();
    }
  });
}

function makePrioCell(prio, disabled) {
  // use default priority if no prio passed; also disable the input in this case
  var useDefaultPrio = !prio;
  var defaultPrio = $('#editor-default-priority').data('initial-value');
  if (!defaultPrio) {
    defaultPrio = 50;
  }
  if (!prio) {
    prio = defaultPrio;
  }

  var td = $('<td class="prio"></td>');
  var prioInput = $('<input type="number"></input>');
  if (!useDefaultPrio) {
    prioInput.val(prio);
  }
  prioInput.change(function () {
    priorityChanged($(this));
  });
  prioInput.prop('disabled', disabled);
  prioInput.attr('placeholder', defaultPrio);
  prioInput.appendTo(td);
  return td;
}

function buildMediumGroup(group, media) {
  var div = $('<div class="jobtemplate-medium"/>').appendTo('#media');
  div.append('<div class="jobtemplate-header">' + group + '</div>');
  var table = $('<table class="table table-striped mediagroup" id="' + group + '"/>').appendTo(div);
  var thead = $('<thead/>').appendTo(table);
  var tr = $('<tr/>').appendTo(thead);
  var tname = tr.append($('<th class="name">Test</th>'));
  var prioHeading = $('<th class="prio">Prio</th>');
  prioHeading.css('white-space', 'nowrap');
  var prioHelpPopover = $(
    '<a href="#" class="help_popover fa fa-question-circle"" data-content="' +
      'The priority can be set for each row specifically. However, the priority might be left empty as well. ' +
      'In this case default priority for the whole job group is used (displayed in italic font)." data-toggle="popover" ' +
      'data-trigger="focus" role="button"></a>'
  );
  prioHelpPopover.popover({html: true});
  prioHeading.append(prioHelpPopover);
  tr.append(prioHeading);
  var archs = {};
  var tests = {};
  var prio = 444;
  $.each(media, function (index, temp) {
    var a = archs[temp.product.arch];
    if (!a) a = {};
    if (!Object.prototype.hasOwnProperty.call(a, temp.test_suite.name)) {
      a[temp.test_suite.name] = [];
      table.data('product-' + temp.product.arch, temp.product.id);
      a['_id'] = temp.product.id;
    }
    a[temp.test_suite.name].push(temp);
    archs[temp.product.arch] = a;
    tests[temp.test_suite.name] = {
      prio: temp.prio,
      id: temp.test_suite.id
    };
  });
  var archnames = Object.keys(archs).sort();
  table.data('archs', archnames);
  var testnames = Object.keys(tests).sort();
  $.each(archnames, function (index, arch) {
    var a = $('<th class="arch arch_' + arch + '">' + arch + '</th>').appendTo(tr);
  });
  var tbody = $('<tbody/>').appendTo(table);
  $.each(testnames, function (ti, test) {
    var tr = $('<tr class="test_' + test + '"/>').appendTo(tbody);
    tr.data('test-id', tests[test]['id']);
    var shortname = test;
    if (test.length >= 70) {
      shortname = '<span title=' + test + '>' + test.substr(0, 67) + '…</span>';
    }
    $('<td class="name">' + shortname + '</td>').appendTo(tr);
    makePrioCell(tests[test].prio, false).appendTo(tr);

    $.each(archnames, function (archIndex, arch) {
      var td = $('<td class="arch"/>').appendTo(tr);
      var select = $('#machines-template').clone().appendTo(td);
      select.attr('id', group + '-' + arch + '-' + test);
      select.attr('data-product-id', archs[arch]['_id']);
      select.addClass('chosen-select');
      if (
        Object.prototype.hasOwnProperty.call(archs, arch) &&
        Object.prototype.hasOwnProperty.call(archs[arch], test)
      ) {
        $.each(archs[arch][test], function (mi, temp) {
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
  $(table)
    .find('tbody tr')
    .each(function () {
      $(this).find('td.arch').eq(position)[method]('<td class="arch">&nbsp;</td>');
    });
}

function findHeaderWithAllArchitectures() {
  var headerWithAllArchs = [];
  $('table.mediagroup thead').each(function () {
    var archs = $(this).find('th.arch');
    if (archs.length > headerWithAllArchs.length) headerWithAllArchs = archs;
  });
  return headerWithAllArchs;
}

function fillEmptySpace(table, tableHead, headerWithAllArchs) {
  if (tableHead.length < headerWithAllArchs.length) {
    headerWithAllArchs.each(function (i) {
      // Used all ths, fill the rest
      if (tableHead.length == i) {
        for (var j = i; j < headerWithAllArchs.length; j++) {
          addArchSpacer(table, j - 1, 'after');
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
  $('td.name').each(function (index, test) {
    if ($(this).outerWidth() > namewidth) namewidth = $(this).outerWidth();
  });
  namewidth = Math.ceil(namewidth);

  var headerWithAllArchs = findHeaderWithAllArchitectures();

  // Fill empty space
  $('table.mediagroup').each(function (index, table) {
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
  checkJobGroupForm('#group_properties_form');
  if ((window.groupPropertiesEditorVisisble = !window.groupPropertiesEditorVisisble)) {
    document.getElementById('job-config-page-heading').innerHTML = 'Job';
    document.getElementById('job-config-templates-heading').style.display = 'inline';
  } else {
    document.getElementById('job-config-page-heading').innerHTML = 'Job templates for';
    document.getElementById('job-config-templates-heading').style.display = 'none';
  }
}

function toggleTemplateEditor() {
  $('#media').toggle(250);
  var form = $('#editor-form');
  form.toggle(250);
  form.find('.buttons').hide();
  form.find('.progress-indication').show();
  $('#toggle-yaml-editor').toggleClass('btn-secondary');
  if (editor == undefined) {
    editor = CodeMirror.fromTextArea(document.getElementById('editor-template'), {
      mode: 'yaml',
      lineNumbers: true,
      lineWrapping: true,
      readOnly: 'nocursor',
      viewportMargin: Infinity
    });
    editor.setOption('extraKeys', {
      Tab: function (editor) {
        // Convert tabs to spaces
        editor.replaceSelection(Array(editor.getOption('indentUnit') + 1).join(' '));
      }
    });

    $('.CodeMirror').css('width', window.innerWidth * 0.9 + 'px');
    $('.CodeMirror').css('height', window.innerHeight * 0.7 + 'px');
    $(window).on('resize', function () {
      $('.CodeMirror').css('height', window.innerHeight * 0.7 + 'px');
    });
    $('#toggle-yaml-guide').click(function () {
      $('.editor-yaml-guide').toggle();
      var guide_width = $('.editor-yaml-guide').is(':visible') ? $('.editor-yaml-guide').width() : 0;
      $('.CodeMirror').css('width', window.innerWidth * 0.9 - guide_width + 'px');
    });
  }
  $.ajax({
    url: form.data('put-url'),
    dataType: 'json'
  }).done(prepareTemplateEditor);
}

function prepareTemplateEditor(data) {
  editor.doc.setValue(data);
  var form = $('#editor-form');
  form.find('.progress-indication').hide();
  form.find('.buttons').show();
  if (!user_is_admin) {
    return;
  }

  editor.setOption('readOnly', false);
}

function submitTemplateEditor(button) {
  var form = $('#editor-form');
  form.find('.buttons').hide();
  form.find('.progress-indication').show();
  var result = form.find('.result');
  result.text('Applying changes...');

  // Reset to the minimum viable YAML if empty
  var template = editor.doc.getValue();
  if (template === '') {
    template = 'products: {}\nscenarios: {}\n';
    editor.doc.setValue(template);
  }

  // Ensure final linebreak, as files without it often need additional
  // handling elsewhere
  else if (template.substr(-1) !== '\n') {
    template += '\n';
    editor.doc.setValue(template);
  }

  $.ajax({
    url: form.data('put-url'),
    type: 'POST',
    dataType: 'json',
    data: {
      schema: 'JobTemplates-01.yaml',
      preview: button !== 'save' ? 1 : 0,
      expand: button === 'expand' ? 1 : 0,
      template: template,
      reference: form.data('reference')
    }
  })
    .done(function (data) {
      var mode, value;
      switch (button) {
        case 'expand':
          result.text('Result of expanding the YAML:');
          mode = 'yaml';
          value = data.result;
          break;
        case 'preview':
          result.text('Preview of the changes:');
          mode = 'diff';
          value = data.changes;
          break;
        case 'save':
          // Once a valid YAML template was saved we no longer offer the legacy editor
          $('#toggle-yaml-editor').hide();
          $('#media-add').hide();
          // Update the reference to the saved document
          form.data('reference', editor.doc.getValue());

          result.text('YAML saved!');
          mode = 'diff';
          value = data.changes;
          break;
      }

      if (value) {
        var preview = CodeMirror($('<pre/>').appendTo(result)[0], {
          mode: mode,
          lineNumbers: true,
          lineWrapping: true,
          readOnly: true,
          value: value
        });
      } else {
        $('<strong/>').text(' No changes were made!').appendTo(result);
      }
    })
    .fail(function (data) {
      result.text('There was a problem applying the changes:');
      if (!Object.prototype.hasOwnProperty.call(data, 'responseJSON')) {
        $('<p/>')
          .text('Invalid server response: ' + data.statusText)
          .appendTo(result);
        return;
      }
      var data = data.responseJSON;
      if (Object.prototype.hasOwnProperty.call(data, 'error')) {
        var errors = data.error;
        var list = $('<ul/>').appendTo(result);
        $.each(errors, function (i) {
          var message = Object.prototype.hasOwnProperty.call(errors[i], 'message')
            ? errors[i].message + ': ' + errors[i].path
            : errors[i];
          $('<li/>').text(message).appendTo(list);
        });
      }
      if (Object.prototype.hasOwnProperty.call(data, 'changes')) {
        var preview = CodeMirror($('<pre/>').appendTo(result)[0], {
          mode: 'diff',
          lineNumbers: true,
          lineWrapping: true,
          readOnly: true,
          value: data.changes
        });
      }
    })
    .always(function (data) {
      form.find('.buttons').show();
      form.find('.progress-indication').hide();
    });
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
    success: function () {
      showSubmitResults(editorForm, '<i class="fa fa-save"></i> Changes applied');

      // show new name
      var newJobName = $('#editor-name').val();
      $('#job-group-name').text(newJobName);
      document.title = document.title.substr(0, 17) + newJobName;
      // update initial value for default priority (used when adding new job template)
      var defaultPrioInput = $('#editor-default-priority');
      var defaultPrio = defaultPrioInput.val();
      defaultPrioInput.data('initial-value', defaultPrio);
      $('td.prio input').attr('placeholder', defaultPrio);
    },
    error: function (xhr, ajaxOptions, thrownError) {
      var errmsg = '';
      if (xhr.responseJSON.error) {
        errmsg = xhr.responseJSON.error;
      }
      showSubmitResults(
        editorForm,
        '<i class="fa fa-trash"></i> Unable to apply changes ' + '<strong>' + errmsg + '</strong>'
      );
    }
  });

  return false;
}
