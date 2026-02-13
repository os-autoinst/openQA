var job_templates_url;
var job_group_id;
var user_is_admin;
var editor;

function setupJobTemplates(url, id) {
  job_templates_url = url;
  job_group_id = id;
  fetch(url + '?group_id=' + id)
    .then(response => response.json())
    .then(loadJobTemplates);
}

function loadJobTemplates(data) {
  var mediagroups = {};
  var groups = [];
  data.JobTemplates.forEach(jt => {
    var media = mediagroups[jt.product.group];
    if (!media) {
      groups.push(jt.product.group);
      media = [];
    }
    media.push(jt);
    mediagroups[jt.product.group] = media;
  });
  groups.sort();
  groups.forEach(group => {
    buildMediumGroup(group, mediagroups[group]);
  });
  var width = alignCols() - 16;
  const loading = document.getElementById('loading');
  if (loading) {
    loading.remove();
  }
  const chosenSelects = document.querySelectorAll('.chosen-select');
  chosenSelects.forEach(select => {
    select.dataset.lastSelection = JSON.stringify(Array.from(select.selectedOptions).map(o => o.value));
    select.addEventListener('change', nativeChosenChanged);
  });
}

function highlightChosen(chosen) {
  chosen.style.opacity = 0.3;
  setTimeout(() => {
    chosen.style.opacity = 1;
  }, 200);
}

function nativeChosenChanged(evt) {
  const select = evt.target;
  const currentSelection = Array.from(select.selectedOptions).map(o => o.value);
  const lastSelection = JSON.parse(select.dataset.lastSelection || '[]');

  const added = currentSelection.filter(x => !lastSelection.includes(x));
  const removed = lastSelection.filter(x => !currentSelection.includes(x));

  added.forEach(val => templateAdded(select, val));
  removed.forEach(val => templateRemoved(select, val));

  select.dataset.lastSelection = JSON.stringify(currentSelection);
}

function templateRemoved(chosen, deselected) {
  const option = chosen.querySelector('option[value="' + deselected + '"]');
  const jid = option ? option.dataset.jid : null;
  fetchWithCSRF(job_templates_url + '/' + jid, {method: 'DELETE'})
    .then(() => {
      highlightChosen(chosen);
    })
    .catch(addFailed);
}

function addFailed(data) {
  // display something without alert
  if (data && typeof data === 'object' && data.error) {
    alert(data.error);
  } else {
    alert('unknown error');
  }
}

function addSucceeded(chosen, selected, data) {
  const option = chosen.querySelector('option[value="' + selected + '"]');
  if (option) {
    option.dataset.jid = data['id'];
  }
  highlightChosen(chosen);
}

// after a machine was added the select is final
function finalizeTest(tr) {
  const test_select = tr.querySelector('td.name select');
  if (!test_select) return;

  // disable select and assign the selected ID to the row
  test_select.disabled = true;
  tr.dataset.testId = test_select.options[test_select.selectedIndex].dataset.testId;

  // make test unavailable in other selections
  const tbody = tr.closest('tbody');
  const presentTests = findPresentTests(tbody);
  tbody.querySelectorAll('td.name select').forEach(function (select) {
    if (!select.disabled) {
      filterTestSelection(select, presentTests);
    }
  });
}

function formatPriority(prio) {
  return !prio || prio.length === 0 ? 'inherit' : prio;
}

function templateAdded(chosen, selected) {
  const tr = chosen.closest('tr');
  finalizeTest(tr);
  const prioInput = tr.querySelector('.prio input');
  const option = chosen.querySelector('option[value="' + selected + '"]');
  var postData = new FormData();
  postData.append('prio', formatPriority(prioInput.value));
  postData.append('group_id', job_group_id);
  postData.append('product_id', chosen.dataset.productId);
  postData.append('machine_id', option.dataset.machineId);
  postData.append('test_suite_id', tr.dataset.testId);

  fetchWithCSRF(job_templates_url, {
    method: 'POST',
    body: postData
  })
    .then(response => response.json())
    .then(data => {
      addSucceeded(chosen, selected, data);
    })
    .catch(addFailed);
}

function priorityChanged(priorityInput) {
  const tr = priorityInput.closest('tr');

  // just skip if there are no machines added anyways
  const hasMachines = Array.from(tr.querySelectorAll('td.arch select')).some(select => select.value);
  if (!hasMachines) {
    return;
  }

  const postData = new FormData();
  postData.append('prio', formatPriority(priorityInput.value));
  postData.append('prio_only', true);
  postData.append('group_id', job_group_id);
  postData.append('test_suite_id', tr.dataset.testId);

  fetchWithCSRF(job_templates_url, {
    method: 'POST',
    body: postData
  }).catch(addFailed);
}

function testChanged(evt) {
  const select = evt.target;
  const selectedValue = select.value;
  const noSelection = !selectedValue || selectedValue.length === 0;
  const tr = select.closest('tr');
  const chosens = tr.querySelectorAll('.chosen-select');
  const inputs = tr.querySelectorAll('input');
  chosens.forEach(chosen => {
    chosen.disabled = noSelection;
  });
  inputs.forEach(input => (input.disabled = noSelection));
}

function findPresentTests(table) {
  const presentTests = [];
  table.querySelectorAll('td.name').forEach(function (td) {
    let test;
    const select = td.querySelector('select');
    if (select && select.disabled) {
      test = select.value;
    } else {
      test = td.textContent.trim();
    }
    if (test) {
      presentTests.push(test);
    }
  });
  return presentTests;
}

function filterTestSelection(select, presentTests) {
  Array.from(select.options).forEach(function (option) {
    if (presentTests.indexOf(option.textContent.trim()) >= 0) {
      option.remove();
    }
  });
}

function makePrioCell(prio, disabled) {
  // use default priority if no prio passed; also disable the input in this case
  var useDefaultPrio = !prio;
  var defaultPrioEl = document.getElementById('editor-default-priority');
  var defaultPrio = defaultPrioEl ? defaultPrioEl.dataset.initialValue : null;
  if (!defaultPrio) {
    defaultPrio = 50;
  }
  if (!prio) {
    prio = defaultPrio;
  }

  const td = document.createElement('td');
  td.className = 'prio';
  const prioInput = document.createElement('input');
  prioInput.type = 'number';
  if (!useDefaultPrio) {
    prioInput.value = prio;
  }
  prioInput.addEventListener('change', function () {
    priorityChanged(this);
  });
  prioInput.disabled = disabled;
  prioInput.setAttribute('placeholder', defaultPrio);
  td.appendChild(prioInput);
  return td;
}

function buildMediumGroup(group, media) {
  const mediaContainer = document.getElementById('media');
  const div = document.createElement('div');
  div.className = 'jobtemplate-medium';
  mediaContainer.appendChild(div);

  const header = document.createElement('div');
  header.className = 'jobtemplate-header';
  header.textContent = group;
  div.appendChild(header);

  const table = document.createElement('table');
  table.className = 'table table-striped mediagroup';
  table.id = group;
  div.appendChild(table);

  const thead = document.createElement('thead');
  table.appendChild(thead);
  const trHead = document.createElement('tr');
  thead.appendChild(trHead);

  const thName = document.createElement('th');
  thName.className = 'name';
  thName.textContent = 'Test';
  trHead.appendChild(thName);

  const thPrio = document.createElement('th');
  thPrio.className = 'prio';
  thPrio.style.whiteSpace = 'nowrap';
  thPrio.textContent = 'Prio ';
  const prioHelpPopover = document.createElement('a');
  prioHelpPopover.href = '#';
  prioHelpPopover.className = 'help_popover fa fa-question-circle';
  prioHelpPopover.setAttribute(
    'data-content',
    'The priority can be set for each row specifically. However, the priority might be left empty as well. ' +
      'In this case default priority for the whole job group is used (displayed in italic font).'
  );
  prioHelpPopover.setAttribute('data-bs-toggle', 'popover');
  prioHelpPopover.setAttribute('data-trigger', 'focus');
  prioHelpPopover.setAttribute('role', 'button');
  thPrio.appendChild(prioHelpPopover);
  new bootstrap.Popover(prioHelpPopover, {html: true});
  trHead.appendChild(thPrio);

  var archs = {};
  var tests = {};
  media.forEach(function (temp) {
    var a = archs[temp.product.arch];
    if (!a) a = {};
    if (!Object.prototype.hasOwnProperty.call(a, temp.test_suite.name)) {
      a[temp.test_suite.name] = [];
      table.dataset['product' + temp.product.arch] = temp.product.id;
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
  table.dataset.archs = JSON.stringify(archnames);
  var testnames = Object.keys(tests).sort();
  archnames.forEach(function (arch) {
    const thArch = document.createElement('th');
    thArch.className = 'arch arch_' + arch;
    thArch.textContent = arch;
    trHead.appendChild(thArch);
  });

  const tbody = document.createElement('tbody');
  table.appendChild(tbody);
  testnames.forEach(function (test) {
    const tr = document.createElement('tr');
    tr.className = 'test_' + test;
    tr.dataset.testId = tests[test].id;
    tbody.appendChild(tr);

    var shortname = test;
    const tdName = document.createElement('td');
    tdName.className = 'name';
    if (test.length >= 70) {
      const span = document.createElement('span');
      span.title = test;
      span.textContent = test.substr(0, 67) + '…';
      tdName.appendChild(span);
    } else {
      tdName.textContent = test;
    }
    tr.appendChild(tdName);

    tr.appendChild(makePrioCell(tests[test].prio, false));

    archnames.forEach(function (arch) {
      const tdArch = document.createElement('td');
      tdArch.className = 'arch';
      tr.appendChild(tdArch);

      const machinesTemplate = document.getElementById('machines-template');
      const select = machinesTemplate.cloneNode(true);
      select.style.display = '';
      select.id = group + '-' + arch + '-' + test;
      select.dataset.productId = archs[arch]._id;
      select.classList.add('chosen-select');
      tdArch.appendChild(select);

      if (
        Object.prototype.hasOwnProperty.call(archs, arch) &&
        Object.prototype.hasOwnProperty.call(archs[arch], test)
      ) {
        archs[arch][test].forEach(function (temp) {
          const option = select.querySelector("option[value='" + temp.machine.name + "']");
          if (option) {
            option.selected = true;
            option.dataset.jid = temp.id;
          }
        });
      }
    });
  });
}

function addArchSpacer(table, position, method) {
  const ths = table.querySelectorAll('thead th.arch');
  const targetTh = ths[position];
  const newTh = document.createElement('th');
  newTh.className = 'arch';
  newTh.innerHTML = '&nbsp;';
  if (method === 'after') {
    targetTh.after(newTh);
  } else {
    targetTh.before(newTh);
  }

  table.querySelectorAll('tbody tr').forEach(function (tr) {
    const tds = tr.querySelectorAll('td.arch');
    const targetTd = tds[position];
    const newTd = document.createElement('td');
    newTd.className = 'arch';
    newTd.innerHTML = '&nbsp;';
    if (method === 'after') {
      targetTd.after(newTd);
    } else {
      targetTd.before(newTd);
    }
  });
}

function findHeaderWithAllArchitectures() {
  let headerWithAllArchs = [];
  document.querySelectorAll('table.mediagroup thead').forEach(function (thead) {
    const archs = Array.from(thead.querySelectorAll('th.arch'));
    if (archs.length > headerWithAllArchs.length) headerWithAllArchs = archs;
  });
  return headerWithAllArchs;
}

function fillEmptySpace(table, tableHead, headerWithAllArchs) {
  if (tableHead.length < headerWithAllArchs.length) {
    headerWithAllArchs.forEach(function (h, i) {
      // Used all ths, fill the rest
      if (tableHead.length == i) {
        for (var j = i; j < headerWithAllArchs.length; j++) {
          addArchSpacer(table, j - 1, 'after');
        }
        return false;
      } else if (h.innerHTML != tableHead[i].innerHTML) {
        addArchSpacer(table, i, 'before');
        tableHead = Array.from(table.querySelectorAll('thead th.arch'));
      }
    });
  }
}

function alignCols() {
  // Set minimal width
  document.querySelectorAll('th.name, th.prio').forEach(el => (el.style.width = '0'));

  // Find biggest minimal width
  var namewidth = 450;
  document.querySelectorAll('td.name').forEach(function (test) {
    if (test.offsetWidth > namewidth) namewidth = test.offsetWidth;
  });
  namewidth = Math.ceil(namewidth);

  var headerWithAllArchs = findHeaderWithAllArchitectures();

  // Fill empty space
  document.querySelectorAll('table.mediagroup').forEach(function (table) {
    fillEmptySpace(table, Array.from(table.querySelectorAll('thead th.arch')), headerWithAllArchs);
  });

  // Compute arch width
  const jobtemplateHeader = document.querySelector('.jobtemplate-header');
  const thPrio = document.querySelector('th.prio');
  var archwidth =
    (jobtemplateHeader ? jobtemplateHeader.offsetWidth : 1000) - namewidth - (thPrio ? thPrio.offsetWidth : 50);
  archwidth = Math.floor(archwidth / headerWithAllArchs.length) - 1;

  document.querySelectorAll('th.name').forEach(el => (el.style.width = namewidth + 'px'));
  document.querySelectorAll('th.arch').forEach(el => (el.style.width = archwidth + 'px'));

  return archwidth;
}

function toggleEdit() {
  const properties = document.getElementById('properties');
  if (properties) {
    properties.style.display = properties.style.display === 'none' ? '' : 'none';
  }
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
  const media = document.getElementById('media');
  if (media) {
    media.style.display = media.style.display === 'none' ? '' : 'none';
  }
  const form = document.getElementById('editor-form');
  if (!form) {
    return;
  }
  form.style.display = form.style.display === 'none' ? '' : 'none';
  form.querySelector('.buttons').style.display = 'none';
  form.querySelector('.progress-indication').style.display = '';
  const toggleYamlEditor = document.getElementById('toggle-yaml-editor');
  if (toggleYamlEditor) {
    toggleYamlEditor.classList.toggle('btn-secondary');
  }
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
  fetch(form.dataset.putUrl, {headers: {Accept: 'application/json'}})
    .then(response => response.json())
    .then(prepareTemplateEditor);
}

function prepareTemplateEditor(data) {
  editor.setValue(data, -1);
  const form = document.getElementById('editor-form');
  if (form) {
    form.querySelector('.progress-indication').style.display = 'none';
    form.querySelector('.buttons').style.display = '';
  }
  if (!user_is_admin) {
    return;
  }

  editor.setOption('readOnly', false);
}

function submitTemplateEditor(button) {
  const form = document.getElementById('editor-form');
  if (!form) {
    return;
  }
  form.querySelector('.buttons').style.display = 'none';
  form.querySelector('.progress-indication').style.display = '';
  const result = form.querySelector('.result');
  result.textContent = 'Applying changes...';

  // Reset to the minimum viable YAML if empty
  var template = editor.getValue();
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

  fetchWithCSRF(form.dataset.putUrl, {
    method: 'POST',
    headers: {Accept: 'application/json'},
    body: new URLSearchParams({
      schema: 'JobTemplates-01.yaml',
      preview: button !== 'save' ? 1 : 0,
      expand: button === 'expand' ? 1 : 0,
      template: template,
      reference: form.dataset.reference
    })
  })
    .then(response => {
      return response.json();
    })
    .then(data => {
      // handle errors with YAML syntax
      if (Object.prototype.hasOwnProperty.call(data, 'error')) {
        result.textContent = 'There was a problem applying the changes:';
        var errors = data.error;
        var list = document.createElement('ul');
        result.appendChild(list);
        errors.forEach(err => {
          var message = Object.prototype.hasOwnProperty.call(err, 'message') ? err.message + ': ' + err.path : err;
          var li = document.createElement('li');
          li.textContent = message;
          list.appendChild(li);
        });
        return;
      }

      var mode, value;
      switch (button) {
        case 'expand':
          result.textContent = 'Result of expanding the YAML:';
          mode = 'ace/mode/yaml';
          value = data.result;
          break;
        case 'preview':
          result.textContent = 'Preview of the changes:';
          mode = 'ace/mode/diff';
          value = data.changes;
          break;
        case 'save': {
          // Once a valid YAML template was saved we no longer offer the legacy editor
          const toggleYamlEditor = document.getElementById('toggle-yaml-editor');
          if (toggleYamlEditor) {
            toggleYamlEditor.style.display = 'none';
          }
          const mediaAdd = document.getElementById('media-add');
          if (mediaAdd) {
            mediaAdd.style.display = 'none';
          }
          // Update the reference to the saved document
          form.dataset.reference = editor.getValue();

          result.textContent = 'YAML saved!';
          mode = 'ace/mode/diff';
          value = data.changes;
          break;
        }
      }

      if (value) {
        const previewElement = document.createElement('pre');
        previewElement.appendChild(document.createTextNode(value));
        ace.edit(previewElement, {
          mode: mode,
          readOnly: true,
          maxLines: Infinity
        });
        editor.session.setUseWrapMode(true);
        result.appendChild(previewElement);
      } else {
        const strong = document.createElement('strong');
        strong.textContent = ' No changes were made!';
        result.appendChild(strong);
      }
    })
    .catch(error => {
      result.textContent = 'There was a problem applying the changes:';
      const p = document.createElement('p');
      p.textContent = error;
      result.appendChild(p);
    })
    .finally(() => {
      form.querySelector('.buttons').style.display = '';
      form.querySelector('.progress-indication').style.display = 'none';
    });
}

function showSubmitResults(form, result) {
  const buttons = form.querySelector('.buttons');
  if (buttons) buttons.style.display = '';
  const progress = form.querySelector('.properties-progress-indication');
  if (progress) progress.style.display = 'none';
  const status = form.querySelector('.properties-status');
  if (status) status.innerHTML = result;
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
  form.querySelector('.buttons').style.display = 'none';
  const progress = form.querySelector('.properties-progress-indication');
  if (progress) progress.style.display = '';
  fetchWithCSRF(form.dataset.putUrl, {method: 'PUT', body: new FormData(form)})
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
      if (overallError) throw overallError;
      if (!response.ok) throw `Server returned ${response.status}: ${response.statusText}`;
      const warnings = json?.warnings_by_field;
      const remark =
        typeof warnings === 'object' && Object.keys(warnings).length > 0
          ? ', but <strong>there are warnings</strong> (see highlighted fields)'
          : '';
      showSubmitResults(form, `<i class="fa fa-save"></i> Changes applied${remark}`);

      // show new name
      var newJobName = document.getElementById('editor-name').value;
      const jobGroupNameEl = document.getElementById('job-group-name');
      if (jobGroupNameEl) {
        jobGroupNameEl.textContent = newJobName;
      }
      document.title = document.title.substr(0, 17) + newJobName;
      // update initial value for default priority (used when adding new job template)
      var defaultPrioInput = document.getElementById('editor-default-priority');
      var defaultPrio = defaultPrioInput.value;
      defaultPrioInput.dataset.initialValue = defaultPrio;
      document.querySelectorAll('td.prio input').forEach(input => {
        input.setAttribute('placeholder', defaultPrio);
      });
    })
    .catch(error => {
      showSubmitResults(
        form,
        `<i class="fa fa-exclamation-circle"></i> Unable to apply changes: <strong>${error}</strong>`
      );
    });

  return false;
}
