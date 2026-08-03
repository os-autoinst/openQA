let scenarioDefinitionsEditor;
let settingsEditor;

export function getNonEmptyFormParams(form) {
  const formData = new FormData(form);
  const queryParams = new URLSearchParams();
  for (const [key, value] of formData) {
    if (value.length > 0) {
      queryParams.append(key, value);
    }
  }
  return queryParams;
}

export function setupAceEditor(elementID, mode) {
  const element = document.getElementById(elementID);
  const initialValue = element.textContent;
  const editor = ace.edit(element, {
    mode: mode,
    maxLines: Infinity,
    tabSize: 2,
    useSoftTabs: true
  });
  editor.session.setUseWrapMode(true);
  editor.initialValue = initialValue;
  return editor;
}

export function setupCreateTestsForm() {
  scenarioDefinitionsEditor = setupAceEditor('create-tests-scenario-definitions', 'ace/mode/yaml');
  settingsEditor = setupAceEditor('create-tests-settings', 'ace/mode/ini');
}

export function resetCreateTestsForm() {
  scenarioDefinitionsEditor.setValue(scenarioDefinitionsEditor.initialValue, -1);
  settingsEditor.setValue(settingsEditor.initialValue, -1);
}

export function createTests(form) {
  const scenarioDefinitions = scenarioDefinitionsEditor.getValue();
  const queryParams = getNonEmptyFormParams(form);
  settingsEditor
    .getValue()
    .split('\n')
    .map(line => line.split('=', 2))
    .forEach(setting => queryParams.append(setting[0].trim(), (setting[1] ?? '').trim()));
  queryParams.append('async', true);
  if (scenarioDefinitions.length > 0) {
    queryParams.append('SCENARIO_DEFINITIONS_YAML', scenarioDefinitions);
  }
  $.ajax({
    url: form.dataset.postUrl,
    method: form.method,
    data: queryParams.toString(),
    success: function (response) {
      const id = response.scheduled_product_id;
      const url = `${form.dataset.productlogUrl}?id=${id}`;
      addFlash('info', `Tests have been scheduled, check out the <a href="${url}">product log</a> for details.`);
    },
    error: function (xhr, ajaxOptions, thrownError) {
      addFlash('danger', 'Unable to create tests: ' + (xhr.responseJSON?.error ?? xhr.responseText ?? thrownError));
    }
  });
}

export function cloneTests(link) {
  const loadingIndication = document.createElement('span');
  loadingIndication.append('Cloning test distribution …');
  link.parentNode.replaceWith(loadingIndication);
  $.ajax({
    url: document.getElementById('flash-messages').dataset.cloneUrl,
    method: 'POST',
    success: function (response) {
      location.reload();
    },
    error: function (xhr, ajaxOptions, thrownError) {
      const retryButton = '<br/><a class="btn btn-primary clone-tests-btn" href="#">Retry</a>';
      const error = xhr.responseJSON?.error ?? xhr.responseText ?? thrownError;
      loadingIndication.parentNode.classList.replace('alert-primary', 'alert-danger');
      loadingIndication.innerHTML = `Unable to clone: ${error} ${retryButton}`;
    }
  });
}

$(function () {
  if ($('#create-tests-form').length) {
    setupCreateTestsForm();
  }
});

$(document).on('submit', '#create-tests-form', function (e) {
  e.preventDefault();
  createTests(this);
});

$(document).on('reset', '#create-tests-form', function (e) {
  resetCreateTestsForm(this);
});

$(document).on('click', '.clone-tests-btn', function (e) {
  e.preventDefault();
  cloneTests(this);
});
