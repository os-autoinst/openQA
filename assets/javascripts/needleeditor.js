function NeedleEditor(needle) {
  this.textarea = document.getElementById('needleeditor_textarea');
  this.tags = document.getElementById('needleeditor_tags');
  this.canvas = document.getElementById('needleeditor_canvas');
  if (!this.canvas) {
    alert('missing canvas element');
    return;
  }
  this.bgImage = null;
  this.cv = null;
  this.needle = needle;
}

NeedleEditor.prototype.init = function () {
  const editor = this;
  this.canvas.height = this.bgImage.height;
  this.canvas.width = this.bgImage.width;

  if (this.cv) {
    this.cv.set_bgImage(this.bgImage);
    return;
  }

  const cv = (this.cv = new CanvasState(this.canvas));

  cv.set_bgImage(this.bgImage);

  if (this.tags) {
    // If tags is empty, we must populate it with a checkbox for every tag
    if (this.tags.querySelectorAll('input').length == 0) {
      this.needle.tags.forEach(
        function (tag) {
          this.AddTag(tag, true);
        }.bind(this)
      );
      // If the checkboxes are already there, we simply check them all
    } else {
      const inputs = this.tags.querySelectorAll('input');
      for (let i = 0; i < inputs.length; i++) {
        if (this.needle.tags.indexOf(inputs[i].value) >= 0) {
          inputs[i].checked = true;
        } else {
          inputs[i].checked = false;
        }
      }
    }
  }
  this.DrawAreas();
  this.UpdateTextArea();

  // double click switched type
  cv.canvas.addEventListener(
    'dblclick',
    function (e) {
      const selection = editor.selection();
      const shape = selection.shape;
      const a = selection.area;
      if (!shape || !a) {
        return;
      }
      a.type = NeedleEditor.nexttype(a.type);
      shape.fill = NeedleEditor.areacolor(a.type);
      editor.UpdateTextArea();
      cv.redraw();
    },
    true
  );

  cv.canvas.addEventListener(
    'keyup',
    function (e) {
      if (e.key === 'Delete') {
        const idx = cv.get_selection_idx();
        if (idx != -1) {
          editor.needle.area.splice(idx, 1);
          cv.delete_shape_idx(idx);
          editor.UpdateTextArea();
        }
      } else if (e.key === 'Insert') {
        const a = {xpos: 0, ypos: 0, width: MINSIZE, height: MINSIZE, type: 'match'};
        cv.addShape(NeedleEditor.ShapeFromArea(a));
        editor.needle.area.push(a);
        editor.UpdateTextArea();
      }
    },
    true
  );
  cv.shape_changed_cb = function (shape) {
    const idx = cv.get_shape_idx(shape);
    const a = editor.needle.area[idx];
    const click_point = shape.click_point;
    a.xpos = shape.x;
    a.ypos = shape.y;
    a.width = shape.w;
    a.height = shape.h;
    if (click_point) {
      a.click_point = {
        xpos: click_point.x,
        ypos: click_point.y
      };
    } else {
      delete a.click_point;
    }
    editor.UpdateTextArea();
  };
  cv.new_shape_cb = function (x, y) {
    const a = {xpos: x, ypos: y, width: MINSIZE, height: MINSIZE, type: 'match'};
    const shape = NeedleEditor.ShapeFromArea(a);
    cv.addShape(shape);
    editor.needle.area.push(a);
    editor.UpdateTextArea();
    return shape;
  };
  const areaSpecificButtons = document.querySelectorAll('#change-match, #change-margin, #toggle-click-coordinates');
  cv.canvas.addEventListener('shape.selected', function () {
    areaSpecificButtons.forEach(el => {
      el.classList.remove('disabled');
      el.removeAttribute('disabled');
    });
    updateToggleClickCoordinatesButton(editor.currentClickCoordinates());
  });
  cv.canvas.addEventListener('shape.unselected', function () {
    areaSpecificButtons.forEach(el => {
      el.classList.add('disabled');
      el.setAttribute('disabled', '1');
    });
  });

  document.getElementById('needleeditor_name').onchange = function () {
    editor.UpdateCommitMessage(this.value);
  };
};

NeedleEditor.prototype.UpdateCommitMessage = function (needleName) {
  const textarea = document.getElementById('needleeditor_commit_message');
  if (textarea) {
    textarea.placeholder = needleName + ' for ' + textarea.dataset.for;
  }
};

NeedleEditor.prototype.UpdateTextArea = function () {
  if (this.textarea) {
    this.textarea.value = JSON.stringify(this.needle, null, '  ');
  }
};

NeedleEditor.prototype.AddTag = function (tag, checked) {
  const input = document.createElement('input');
  input.type = 'checkbox';
  input.value = tag;
  input.checked = checked;
  input.id = 'tagInput' + this.tags.childNodes.length;
  const editor = this;
  input.addEventListener('click', function (e, f) {
    editor.changeTag(e.target.value, e.target.checked);
  });
  const div = document.createElement('div');
  const label = document.createElement('label');
  label.appendChild(document.createTextNode(tag));
  label.htmlFor = input.id;
  label.style.fontWeight = 'bold';
  div.appendChild(input);
  div.appendChild(label);
  this.tags.appendChild(div);
  return input;
};

NeedleEditor.nexttype = function (type) {
  if (type == 'match') {
    return 'exclude';
  } else if (type == 'exclude') {
    return 'ocr';
  }
  return 'match';
};

NeedleEditor.ShapeFromArea = function (a) {
  return new Shape(a.xpos, a.ypos, a.width, a.height, NeedleEditor.areacolor(a.type), a.click_point);
};

NeedleEditor.prototype.DrawAreas = function () {
  const editor = this;
  // not yet there
  if (!editor.cv) return false;

  editor.needle.area.forEach(function (area, index) {
    editor.cv.addShape(NeedleEditor.ShapeFromArea(area));
  });
  return true;
};

NeedleEditor.prototype.LoadBackground = function (url) {
  const editor = this;
  const image = new Image();
  editor.bgImage = image;
  image.src = url;
  image.onload = function () {
    editor.init();
  };
};

NeedleEditor.prototype.LoadTags = function (tags) {
  this.needle.tags = tags;
  this.UpdateTextArea();
};

NeedleEditor.prototype.LoadProperty = function (property) {
  this.needle.properties = property;
  this.UpdateTextArea();
};

NeedleEditor.prototype.LoadNeedle = function (url) {
  fetch(url)
    .then(response => {
      if (response.status === 200) return response.json();
      if (response.status === 404) return JSON.parse('{ "area": [], "tags": [] , "properties": [] }');
      throw response;
    })
    .then(data => {
      editor.needle = data;
      editor.init();
    })
    .catch(error => {
      const ctx = editor.canvas.getContext('2d');
      ctx.font = '20pt Verdana';
      ctx.fillText('Failed to load Needle, Code ' + (error.status || error), 10, 50);
    });
};

NeedleEditor.prototype.LoadAreas = function (areas) {
  const editor = this;

  editor.needle.area = areas;
  if (this.cv) {
    this.cv.delete_shapes();
  }
  this.DrawAreas();
  this.UpdateTextArea();
};

NeedleEditor.areacolors = {
  match: 'rgba(  0, 255, 0, .5)',
  exclude: 'rgba(255,   0, 0, .5)',
  ocr: 'rgba(255, 255, 0, .5)'
};

NeedleEditor.areacolor = function (type) {
  if (type in NeedleEditor.areacolors) {
    return NeedleEditor.areacolors[type];
  }
  return 'pink';
};

NeedleEditor.prototype.changeTag = function (name, enabled) {
  const tags = this.needle.tags;
  if (enabled) {
    tags.push(name);
    tags.sort();
  } else {
    const idx = tags.indexOf(name);
    tags.splice(idx, 1);
  }
  this.UpdateTextArea();
};

NeedleEditor.prototype.changeProperty = function (name, enabled) {
  const properties = this.needle.properties;

  if (enabled) {
    properties.push({name: name});
  } else {
    for (let i = 0; i < properties.length; i++) {
      if (properties[i].name === name) {
        properties.splice(i, 1);
        break;
      }
    }
  }
  this.UpdateTextArea();
};

NeedleEditor.prototype.changeWorkaroundDesc = function (value) {
  const properties = this.needle.properties;
  for (let i = 0; i < properties.length; i++) {
    if (properties[i].name === 'workaround') {
      properties[i].value = value;
      break;
    }
  }
  this.UpdateTextArea();
};

NeedleEditor.prototype.selection = function () {
  const cv = this.cv;
  let idx = cv.get_selection_idx();
  const areas = this.needle.area;
  if (idx == -1) {
    if (!areas.length) {
      return {};
    }
    idx = 0;
  }
  return {
    index: idx,
    area: areas[idx],
    shape: cv.shapes[idx]
  };
};

NeedleEditor.prototype.selectedArea = function () {
  return this.selection().area;
};

NeedleEditor.prototype.setMargin = function (value) {
  const selectedArea = this.selectedArea();
  if (!selectedArea) {
    return;
  }
  selectedArea.margin = parseInt(value);
  this.UpdateTextArea();
};

NeedleEditor.prototype.setMatch = function (value) {
  const selectedArea = this.selectedArea();
  if (!selectedArea) {
    return;
  }
  selectedArea.match = parseFloat(value);
  this.UpdateTextArea();
};

NeedleEditor.prototype.currentClickCoordinates = function () {
  const selectedArea = this.selectedArea();
  return selectedArea ? selectedArea.click_point : undefined;
};

NeedleEditor.prototype.toggleClickCoordinates = function () {
  const selection = this.selection();
  const selectedArea = selection.area;
  const selectedShape = selection.shape;
  if (!selectedArea || !selectedShape) {
    return;
  }

  let clickPoint = selectedArea.click_point;
  if (clickPoint) {
    // remove existing click point
    delete selectedArea.click_point;
    delete selectedShape.click_point;
  } else {
    // initialize new click point to be the middle of the area
    clickPoint = selectedArea.click_point = {
      xpos: selectedArea.width / 2,
      ypos: selectedArea.height / 2
    };
    selectedShape.assign_click_point(clickPoint);

    // remove click point from other areas so only one click point per needle is possible
    const selectedIndex = selection.index;
    const areas = this.needle.area;
    const shapes = this.cv.shapes;
    for (let i = 0; i != areas.length; ++i) {
      if (i == selectedIndex) {
        continue;
      }
      delete areas[i].click_point;
      delete shapes[i].click_point;
    }
  }

  // update canvas and text area
  this.cv.redraw();
  this.UpdateTextArea();
  return clickPoint;
};

function loadBackground() {
  const needle = window.needles[document.getElementById('image_select').value];
  nEditor.LoadBackground(needle.imageurl);
  document.getElementById('needleeditor_image').value = needle.imagename || '';
  document.getElementById('needleeditor_imagedistri').value = needle.imagedistri || '';
  document.getElementById('needleeditor_imageversion').value = needle.imageversion || '';
  document.getElementById('needleeditor_imagedir').value = needle.imagedir || '';
}

function loadTagsAndName() {
  const needle = window.needles[document.getElementById('tags_select').value];
  const tags = needle.tags;
  document.querySelectorAll('#needleeditor_tags input').forEach(function (input) {
    input.checked = tags.indexOf(input.value) !== -1;
  });

  let workaroundFlag = 0;
  for (let i = 0; i < needle.properties.length; i++) {
    if (needle.properties[i].name === 'workaround') {
      document.getElementById('property_workaround').checked = true;
      document.getElementById('input_workaround_desc').value = needle.properties[i].value ?? '';
      document.getElementById('workaround_reason').style.display = 'block';
      workaroundFlag = 1;
      break;
    }
  }
  if (workaroundFlag === 0) {
    document.getElementById('property_workaround').checked = false;
    document.getElementById('input_workaround_desc').value = '';
    document.getElementById('workaround_reason').style.display = 'none';
  }

  document.getElementById('needleeditor_name').value = needle.suggested_name || '';
  document.getElementById('area_select').value = needle.name || '';
  loadAreas();
  nEditor.LoadTags(tags);
  nEditor.LoadProperty(needle.properties);
  nEditor.UpdateCommitMessage(needle.suggested_name);
}

function loadAreas() {
  const needle = window.needles[document.getElementById('area_select').value];
  if (document.getElementById('take_matches').checked) {
    // merge exclude areas into matches if not done yet
    const matches = needle.matches;
    if (!matches.hasIncludes) {
      needle.area.forEach(function (area, index) {
        if (area.type === 'exclude') {
          matches.push(area);
        }
      });
      matches.hasIncludes = true;
    }
    nEditor.LoadAreas(needle.matches);
  } else {
    nEditor.LoadAreas(needle.area);
  }
}

function addTag() {
  const input = document.getElementById('newtag');
  if (!input) return false;
  const checkbox = nEditor.AddTag(input.value, false);
  input.value = '';
  input.dispatchEvent(new Event('keyup'));
  checkbox.click();
  return false;
}

function setMargin() {
  nEditor.setMargin(document.getElementById('margin').value);
}

function setMatch() {
  nEditor.setMatch(document.getElementById('match').value);
}

function toggleClickCoordinates() {
  updateToggleClickCoordinatesButton(nEditor.toggleClickCoordinates());
}

function updateToggleClickCoordinatesButton(hasClickCoordinates) {
  document.getElementById('toggle-click-coordinates-verb').textContent = hasClickCoordinates ? 'Remove' : 'Add';
}

function hasMatchAreas(areas) {
  return Array.isArray(areas) && areas.find(area => area.type === 'match');
}

function saveNeedle(overwrite) {
  const form = document.getElementById('save_needle_form');
  const errors = [];
  const tagSelection = window.needles[document.getElementById('tags_select').value];
  if (tagSelection && !tagSelection.tags.length) {
    errors.push('No tags specified.');
  }
  const areaSelection = window.needles[document.getElementById('area_select').value];
  const takeMatchesChecked = document.getElementById('take_matches').checked;
  if (areaSelection && !hasMatchAreas(takeMatchesChecked ? areaSelection.matches : areaSelection.area)) {
    errors.push('At least one match area must be defined.');
  }
  if (errors.length) {
    addFlash('danger', '<strong>Unable to save needle:</strong><ul><li>' + errors.join('</li><li>') + '</li></ul>');
    return false;
  }

  const propWorkaround = document.getElementById('property_workaround');
  const inputWorkaroundDesc = document.getElementById('input_workaround_desc');
  if (!overwrite && propWorkaround.checked && !inputWorkaroundDesc.value) {
    const confirmMessage =
      'You set the workaround property for this needle without a description. Are you sure you want to save without a description?';
    if (!confirm(confirmMessage)) {
      return false;
    }
  }

  document.getElementById('needle_editor_save_buttons').style.display = 'none';
  document.getElementById('needle_editor_loading_indication').style.display = 'block';

  document.getElementById('save').disabled = true;
  document.getElementById('needleeditor_overwrite').value = overwrite ? '1' : '0';

  fetchWithCSRF(form.action, {method: 'POST', body: new FormData(form)})
    .then(handleJSONResponseOrThrow)
    .then(({response, json}) => {
      if (!response.ok) throw `Server returned ${response.status}: ${response.statusText}<br>${json.error || ''}`;
      if (json.error) throw json.error;
      return json;
    })
    .then(response => {
      if (response.requires_overwrite) {
        delete response.requires_overwrite;
        const modalElement = document.getElementById('modal-overwrite');
        modalElement.dataset.formdata = response;
        modalElement.getElementsByClassName('modal-title')[0].textContent = `Sure to overwrite ${response.needlename}?`;
        if (!window.overwriteModal) {
          window.overwriteModal = new bootstrap.Modal(modalElement);
        }
        window.overwriteModal.show();
      } else if (response.success) {
        // add note to go back or restart
        if (response.developer_session_job_id) {
          response.success +=
            " - <a href='" +
            urlWithBase('/tests/' + response.developer_session_job_id) +
            "#live'>back to live view</a>";
        } else if (response.restart) {
          response.success += " - <a href='#' data-url='" + response.restart + "' class='restart-link'>restart job</a>";
        }
        addFlash('info', response.success);
      } else {
        throw `<b>Unknown Error:</b><code>${response}</code>`;
      }
    })
    .catch(error => {
      console.error(error);
      // add context to the error message unless it starts with an HTML tag (and is therefore assumed to be
      // already nicely formatted)
      if (!`${error}`.startsWith('<')) error = `<b>Fatal error when saving needle.</b><br>${error}`;
      addFlash('danger', error);
    })
    .finally(() => {
      document.getElementById('needle_editor_loading_indication').style.display = 'none';
      document.getElementById('needle_editor_save_buttons').style.display = 'block';
      document.getElementById('save').disabled = false;
    });
  if (window.overwriteModal) {
    window.overwriteModal.hide();
  }
  return false;
}

let nEditor;

function submitMargin(event) {
  if (event) event.preventDefault();
  setMargin();
  const modalEl = document.getElementById('change-margin-form');
  const modal = bootstrap.Modal.getInstance(modalEl);
  if (modal) modal.hide();
  return false;
}

function submitMatch(event) {
  if (event) event.preventDefault();
  setMatch();
  const modalEl = document.getElementById('change-match-form');
  const modal = bootstrap.Modal.getInstance(modalEl);
  if (modal) modal.hide();
  return false;
}

function setup_needle_editor(imageurl, default_needle) {
  nEditor = new NeedleEditor(imageurl, default_needle);

  document.querySelectorAll('.tag_checkbox').forEach(el => {
    el.addEventListener('click', function () {
      nEditor.changeTag(this.value, this.checked);
    });
  });

  const tagAddButton = document.getElementById('tag_add_button');
  if (tagAddButton) tagAddButton.addEventListener('click', addTag);
  const newTagInput = document.getElementById('newtag');
  if (newTagInput) {
    newTagInput.addEventListener('keypress', function (event) {
      if (event.key === 'Enter') return addTag();
      return true;
    });
  }

  const propertyWorkaround = document.getElementById('property_workaround');
  propertyWorkaround.addEventListener('click', function () {
    nEditor.changeProperty(this.name, this.checked);
    document.getElementById('workaround_reason').style.display = this.checked ? 'block' : 'none';
  });

  document.getElementById('input_workaround_desc').addEventListener('blur', function () {
    nEditor.changeWorkaroundDesc(this.value);
  });

  document.getElementById('image_select').addEventListener('change', loadBackground);
  // load default
  loadBackground();
  document.getElementById('tags_select').addEventListener('change', loadTagsAndName);
  loadTagsAndName();
  document.getElementById('area_select').addEventListener('change', loadAreas);
  document.getElementById('take_matches').addEventListener('change', loadAreas);
  document.getElementById('match_form').addEventListener('submit', submitMatch);
  document.getElementById('margin_form').addEventListener('submit', submitMargin);

  document.getElementById('change-margin-form').addEventListener('show.bs.modal', function () {
    let idx = nEditor.cv.get_selection_idx();
    if (idx === -1) {
      if (!nEditor.needle.area.length) {
        return;
      }
      idx = 0;
    }
    document.getElementById('margin').value = nEditor.needle.area[idx].margin || 50;
  });
  document.getElementById('change-match-form').addEventListener('show.bs.modal', function () {
    let idx = nEditor.cv.get_selection_idx();
    if (idx == -1) {
      if (!nEditor.needle.area.length) {
        return;
      }
      idx = 0;
    }
    document.getElementById('match').value = nEditor.needle.area[idx].match || 96;
  });

  const reviewJson = document.getElementById('review_json');
  new bootstrap.Popover(reviewJson, {
    trigger: 'focus',
    content: function () {
      return document.getElementById('needleeditor_textarea').value;
    },
    template:
      '<div class="popover" role="tooltip"><div class="arrow"></div><h3 class="popover-header"></h3><pre class="popover-body"></pre></div>'
  });

  // invoke "saveNeedle()" when the "Save" button or the "Overrite" button is clicked
  document.getElementById('save_needle_form').onsubmit = saveNeedle.bind(undefined, false);
  document.getElementById('modal-overwrite-confirm').onclick = saveNeedle.bind(undefined, true);

  if (newTagInput) {
    ['propertychange', 'change', 'click', 'keyup', 'input', 'paste'].forEach(evt => {
      newTagInput.addEventListener(evt, function () {
        const invalid = !this.value.length || !this.validity.valid;
        if (tagAddButton) tagAddButton.disabled = invalid;
      });
    });
  }
  document.addEventListener('click', function (event) {
    if (event.target.classList.contains('restart-link')) {
      restartJob(event.target.dataset.url, window.jobId);
      event.preventDefault();
    }
  });
}
