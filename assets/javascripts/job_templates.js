let user_is_admin;
let editor;

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

function setupTemplateEditor() {
  const form = $('#editor-form');
  form.show();
  form.find('.buttons').hide();
  form.find('.progress-indication').show();
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
