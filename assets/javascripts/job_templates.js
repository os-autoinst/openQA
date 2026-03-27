let job_templates_url;
let job_group_id;
let user_is_admin;
let editor;

function setupJobTemplates(url, id) {
  job_templates_url = url;
  job_group_id = id;
  $.ajax(url + '?group_id=' + id).done(loadJobTemplates);
}

function loadJobTemplates(data) {
  const mediagroups = {};
  const groups = [];
  $.each(data.JobTemplates, function (i, jt) {
    let media = mediagroups[jt.product.group];
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
  const width = alignCols() - 16;
  $('#loading').remove();
  $('.chosen-select').chosen({width: width + 'px'});
  $(document).on('change', '.chosen-select', chosenChanged);
}

function highlightChosen(chosen) {
  const container = chosen.parent('td').find('.chosen-container');
  container.fadeTo('fast', 0.3).fadeTo('fast', 1);
}

function templateRemoved(chosen, deselected) {
  const jid = chosen.find('option[value="' + deselected + '"]').data('jid');
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
  const test_select = tr.find('td.name select');
  if (!test_select.length) return;

  // disable select and assign the selected ID to the row
  test_select.prop('disabled', true);
  tr.data('test-id', test_select.find('option:selected').data('test-id'));

  // make test unavailable in other selections
  const tbody = tr.parents('tbody');
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
  const tr = chosen.parents('tr');
  finalizeTest(tr);
  const postData = {
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
  const tr = priorityInput.parents('tr');

  // just skip if there are no machines added anyways
  const hasMachines = tr.find('td.arch select option:selected').length > 0;
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
  const select = $(this);
  const selectedValue = select.find('option:selected').val();
  const noSelection = !selectedValue || selectedValue.length === 0;
  const tr = select.parents('tr');
  const chosens = tr.find('.chosen-select');
  const inputs = tr.find('input');
  chosens.prop('disabled', noSelection).trigger('chosen:updated');
  inputs.prop('disabled', noSelection);
}

function findPresentTests(table) {
  const presentTests = [];
  table.find('td.name').each(function (index, td) {
    let test;
    const select = $(td).find('select');
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
  const useDefaultPrio = !prio;
  let defaultPrio = $('#editor-default-priority').data('initial-value');
  if (!defaultPrio) {
    defaultPrio = 50;
  }
  if (!prio) {
    prio = defaultPrio;
  }

  const td = $('<td class="prio"></td>');
  const prioInput = $('<input type="number"></input>');
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
  const div = $('<div class="jobtemplate-medium"/>').appendTo('#media');
  div.append('<div class="jobtemplate-header">' + group + '</div>');
  const table = $('<table class="table table-striped mediagroup" id="' + group + '"/>').appendTo(div);
  const thead = $('<thead/>').appendTo(table);
  const tr = $('<tr/>').appendTo(thead);
  const tname = tr.append($('<th class="name">Test</th>'));
  const prioHeading = $('<th class="prio">Prio</th>');
  prioHeading.css('white-space', 'nowrap');
  const prioHelpPopover = $(
    '<a href="#" class="help_popover fa-solid fa-circle-question"" data-content="' +
      'The priority can be set for each row specifically. However, the priority might be left empty as well. ' +
      'In this case default priority for the whole job group is used (displayed in italic font)." data-bs-toggle="popover" ' +
      'data-trigger="focus" role="button"></a>'
  );
  prioHelpPopover.popover({html: true});
  prioHeading.append(prioHelpPopover);
  tr.append(prioHeading);
  const archs = {};
  const tests = {};
  const prio = 444;
  $.each(media, function (index, temp) {
    let a = archs[temp.product.arch];
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
  const archnames = Object.keys(archs).sort();
  table.data('archs', archnames);
  const testnames = Object.keys(tests).sort();
  $.each(archnames, function (index, arch) {
    const a = $('<th class="arch arch_' + arch + '">' + arch + '</th>').appendTo(tr);
  });
  const tbody = $('<tbody/>').appendTo(table);
  $.each(testnames, function (ti, test) {
    const tr = $('<tr class="test_' + test + '"/>').appendTo(tbody);
    tr.data('test-id', tests[test]['id']);
    let shortname = test;
    if (test.length >= 70) {
      shortname = '<span title=' + test + '>' + test.substr(0, 67) + '…</span>';
    }
    $('<td class="name">' + shortname + '</td>').appendTo(tr);
    makePrioCell(tests[test].prio, false).appendTo(tr);

    $.each(archnames, function (archIndex, arch) {
      const td = $('<td class="arch"/>').appendTo(tr);
      const select = $('#machines-template').clone().appendTo(td);
      select.attr('id', group + '-' + arch + '-' + test);
      select.attr('data-product-id', archs[arch]['_id']);
      select.addClass('chosen-select');
      if (
        Object.prototype.hasOwnProperty.call(archs, arch) &&
        Object.prototype.hasOwnProperty.call(archs[arch], test)
      ) {
        $.each(archs[arch][test], function (mi, temp) {
          const option = select.find("option[value='" + temp.machine.name + "']").prop('selected', true);
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
  let headerWithAllArchs = [];
  $('table.mediagroup thead').each(function () {
    const archs = $(this).find('th.arch');
    if (archs.length > headerWithAllArchs.length) headerWithAllArchs = archs;
  });
  return headerWithAllArchs;
}

function fillEmptySpace(table, tableHead, headerWithAllArchs) {
  if (tableHead.length < headerWithAllArchs.length) {
    headerWithAllArchs.each(function (i) {
      // Used all ths, fill the rest
      if (tableHead.length == i) {
        for (let j = i; j < headerWithAllArchs.length; j++) {
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
  let namewidth = 450;
  $('td.name').each(function (index, test) {
    if ($(this).outerWidth() > namewidth) namewidth = $(this).outerWidth();
  });
  namewidth = Math.ceil(namewidth);

  const headerWithAllArchs = findHeaderWithAllArchitectures();

  // Fill empty space
  $('table.mediagroup').each(function (index, table) {
    fillEmptySpace(table, $(this).find('thead th.arch'), headerWithAllArchs);
  });

  // Compute arch width
  let archwidth = $('.jobtemplate-header').outerWidth() - namewidth - $('th.prio').outerWidth();
  archwidth = Math.floor(archwidth / headerWithAllArchs.length) - 1;

  $('th.name').outerWidth(namewidth);
  $('th.arch').outerWidth(archwidth);

  return archwidth;
}

function toggleEdit() {
  $('#properties').toggle(250);
  validateJobGroupForm(document.getElementById('group_properties_form'));
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
  const form = $('#editor-form');
  form.toggle(250);
  form.find('.buttons').hide();
  form.find('.progress-indication').show();
  $('#toggle-yaml-editor').toggleClass('btn-secondary');
  if (editor === undefined) {
    editor = ace.edit('editor-template', {
      mode: 'ace/mode/yaml',
      maxLines: Infinity,
      tabSize: 2,
      useSoftTabs: true
    });
    editor.session.setUseWrapMode(true);
    document.getElementById('toggle-yaml-guide').onclick = function () {
      const editorElements = Array.from(document.getElementsByClassName('editor-container'));
      const yamlGuideElements = Array.from(document.getElementsByClassName('editor-yaml-guide'));
      if (yamlGuideElements[0].style.display === 'none') {
        editorElements.forEach(e => {
          e.classList.add('col-sm-7');
          e.classList.remove('col-sm-12');
        });
        yamlGuideElements.forEach(e => (e.style.display = 'initial'));
      } else {
        editorElements.forEach(e => {
          e.classList.remove('col-sm-7');
          e.classList.add('col-sm-12');
        });
        yamlGuideElements.forEach(e => (e.style.display = 'none'));
      }
    };
  }
  $.ajax({
    url: form.data('put-url'),
    dataType: 'json'
  }).done(prepareTemplateEditor);
}

function prepareTemplateEditor(data) {
  editor.setValue(data, -1);
  const form = $('#editor-form');
  form.find('.progress-indication').hide();
  form.find('.buttons').show();
  if (!user_is_admin) {
    return;
  }

  editor.setOption('readOnly', false);
}

function submitTemplateEditor(button) {
  const form = $('#editor-form');
  form.find('.buttons').hide();
  form.find('.progress-indication').show();
  const result = form.find('.result');
  result.text('Applying changes...');

  // Reset to the minimum viable YAML if empty
  let template = editor.getValue();
  if (!template) {
    template = 'products: {}\nscenarios: {}\n';
    editor.setValue(template, -1);
  }

  // Ensure final linebreak, as files without it often need additional
  // handling elsewhere
  else if (template.substr(-1) !== '\n') {
    template += '\n';
    editor.setValue(template, -1);
  }

  const data = fetchWithCSRF(form.data('put-url'), {
    method: 'POST',
    headers: {Accept: 'application/json'},
    body: new URLSearchParams({
      schema: 'JobTemplates-01.yaml',
      preview: button !== 'save' ? 1 : 0,
      expand: button === 'expand' ? 1 : 0,
      template: template,
      reference: form.data('reference')
    })
  })
    .then(response => {
      return response.json();
    })
    .then(data => {
      // handle errors with YAML syntax
      if (Object.prototype.hasOwnProperty.call(data, 'error')) {
        result.text('There was a problem applying the changes:');
        const errors = data.error;
        const list = $('<ul/>').appendTo(result);
        $.each(errors, function (i) {
          const message = Object.prototype.hasOwnProperty.call(errors[i], 'message')
            ? errors[i].message + ': ' + errors[i].path
            : errors[i];
          $('<li/>').text(message).appendTo(list);
        });
        return;
      }

      let mode, value;
      switch (button) {
        case 'expand':
          result.text('Result of expanding the YAML:');
          mode = 'ace/mode/yaml';
          value = data.result;
          break;
        case 'preview':
          result.text('Preview of the changes:');
          mode = 'ace/mode/diff';
          value = data.changes;
          break;
        case 'save':
          // Once a valid YAML template was saved we no longer offer the legacy editor
          $('#toggle-yaml-editor').hide();
          $('#media-add').hide();
          // Update the reference to the saved document
          form.data('reference', editor.getValue());

          result.text('YAML saved!');
          mode = 'ace/mode/diff';
          value = data.changes;
          break;
      }

      if (value) {
        const previewElement = document.createElement('pre');
        previewElement.appendChild(document.createTextNode(value));
        const preview = ace.edit(previewElement, {
          mode: mode,
          readOnly: true,
          maxLines: Infinity
        });
        editor.session.setUseWrapMode(true);
        result.append(previewElement);
      } else {
        $('<strong/>').text(' No changes were made!').appendTo(result);
      }
    })
    .catch(error => {
      result.text('There was a problem applying the changes:');
      $('<p/>').text(error).appendTo(result);
    })
    .finally(() => {
      form.find('.buttons').show();
      form.find('.progress-indication').hide();
    });
}

function showSubmitResults(form, result) {
  form.find('.buttons').show();
  form.find('.properties-progress-indication').hide();
  form.find('.properties-status').html(result);
}

// adds/removes "is-invalid"/"invalid-feedback" classes/elements within the specified form for the specified response
// returns the overall error with mentionings of internal field names replaced with labels from the form
function updateValidation(form, response) {
  const E = createElement;
  const errorsByField = response?.errors_by_field ?? {};
  const warningsByField = response?.warnings_by_field ?? {};
  const changedFields = response?.changed_fields ?? {};
  const elements = Array.from(form.elements);
  const labels = elements.filter(e => e.labels?.length > 0).map(e => [`'${e.name}'`, `"${e.labels[0].innerText}"`]);
  const applyLabels = msg => labels.reduce((msg, label) => msg.replace(...label), msg);
  const overallError = typeof response.error === 'string' ? applyLabels(response.error) : undefined;
  elements.forEach(element => {
    const fieldName = element.name;
    if (fieldName.length === 0) {
      return;
    }
    const errors = errorsByField[fieldName];
    const warnings = warningsByField[fieldName];
    const newValue = changedFields[fieldName];
    const hasErrors = Array.isArray(errors) && errors.length > 0;
    const hasWarnings = Array.isArray(warnings) && warnings.length > 0;
    const parentElement = element.parentElement;
    let feedbackElement = parentElement.querySelector('.invalid-feedback');
    element.classList[hasErrors || hasWarnings ? 'add' : 'remove']('is-invalid');
    element.classList[hasWarnings ? 'add' : 'remove']('is-invalid-non-critical');
    if (hasErrors || hasWarnings) {
      if (feedbackElement === null) {
        feedbackElement = E('div', [], {class: 'invalid-feedback'});
        parentElement.appendChild(feedbackElement);
      } else {
        feedbackElement.innerHTML = '';
      }
      const addBadge = (className, msg) => feedbackElement.appendChild(E('span', [msg], {class: className}));
      hasErrors && errors.map(applyLabels).forEach(addBadge.bind(undefined, 'badge text-bg-danger'));
      hasWarnings && warnings.map(applyLabels).forEach(addBadge.bind(undefined, 'badge text-bg-warning'));
    } else if (feedbackElement !== null) {
      parentElement.removeChild(feedbackElement);
    }
    if (newValue !== undefined) {
      element.value = newValue;
    }
  });
  return overallError;
}

function showAdvancedFieldsIfJsonRefersToThem(response) {
  const collapse = document.getElementById('show-advanced-cleanup-settings-button');
  if (collapse.getAttribute('aria-expanded') === 'true') {
    return;
  }
  const advancedFields = Array.from(document.querySelectorAll('.advanced-cleanup-settings input')).map(e => e.name);
  const erroneousFields = Object.keys(response?.errors_by_field ?? {});
  const admonitoryFields = Object.keys(response?.warnings_by_field ?? {});
  const containsAdvancedFields = array => array.find(i => advancedFields.includes(i)) !== undefined;
  if (containsAdvancedFields(erroneousFields) || containsAdvancedFields(admonitoryFields)) {
    collapse.click();
  }
}

function submitProperties(form) {
  const editorForm = $(form);
  editorForm.find('.buttons').hide();
  editorForm.find('.progress-indication').show();
  fetchWithCSRF(editorForm.data('put-url'), {
    method: 'PUT',
    body: new FormData(form)
  })
    .then(response => {
      return response
        .json()
        .then(json => {
          // Attach the parsed JSON to the response object for further use
          return {response, json};
        })
        .catch(() => {
          // If parsing fails, handle it as a non-JSON response
          throw `Server returned ${response.status}: ${response.statusText}`;
        });
    })
    .then(({response, json}) => {
      showAdvancedFieldsIfJsonRefersToThem(json);
      const overallError = updateValidation(form, json);
      if (overallError) {
        showSubmitResults(
          editorForm,
          `<i class="fa-solid fa-circle-exclamation"></i> Unable to apply changes: <strong>${overallError}</strong>`
        );
        return;
      }
      if (!response.ok) throw `Server returned ${response.status}: ${response.statusText}`;
      const warnings = json?.warnings_by_field;
      const remark =
        typeof warnings === 'object' && Object.keys(warnings).length > 0
          ? ', but <strong>there are warnings</strong> (see highlighted fields)'
          : '';
      showSubmitResults(editorForm, `<i class="fa-solid fa-floppy-disk"></i> Changes applied${remark}`);

      // show new name
      const newJobName = $('#editor-name').val();
      $('#job-group-name').text(newJobName);
      document.title = document.title.substr(0, 17) + newJobName;
      // update initial value for default priority (used when adding new job template)
      const defaultPrioInput = $('#editor-default-priority');
      const defaultPrio = defaultPrioInput.val();
      defaultPrioInput.data('initial-value', defaultPrio);
      $('td.prio input').attr('placeholder', defaultPrio);
    })
    .catch(error => {
      showSubmitResults(
        editorForm,
        `<i class="fa-solid fa-circle-exclamation"></i> Unable to apply changes: <strong>${error}</strong>`
      );
    })
    .finally(() => {
      editorForm.find('.buttons').show();
      editorForm.find('.progress-indication').hide();
    });

  return false;
}
