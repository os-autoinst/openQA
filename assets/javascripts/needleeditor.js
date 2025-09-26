function NeedleEditor(needle) {
  this.textarea = document.getElementById('needleeditor_textarea');
  this.tags = document.getElementById('needleeditor_tags');
  this.canvas = document.getElementById('needleeditor_canvas');
  if (!this.canvas) {
    alert('missing canvas element ' + canvasid);
    return;
  }
  this.bgImage = null;
  this.cv = null;
  this.needle = needle;
}

NeedleEditor.prototype.init = function () {
  var editor = this;
  this.canvas.height = this.bgImage.height;
  this.canvas.width = this.bgImage.width;

  if (this.cv) {
    this.cv.set_bgImage(this.bgImage);
    return;
  }

  var cv = (this.cv = new CanvasState(this.canvas));

  cv.set_bgImage(this.bgImage);

  if (this.tags) {
    // If tags is empty, we must populate it with a checkbox for every tag
    if (this.tags.getElementsByTagName('input').length == 0) {
      this.needle.tags.forEach(
        function (tag) {
          this.AddTag(tag, true);
        }.bind(this)
      );
      // If the checkboxes are already there, we simply check them all
    } else {
      var inputs = this.tags.getElementsByTagName('input');
      for (var i = 0; i < inputs.length; i++) {
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
      var selection = editor.selection();
      var shape = selection.shape;
      var a = selection.area;
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
      //console.warn("key %d", e.keyCode);
      if (e.keyCode == KeyEvent.DOM_VK_DELETE) {
        var idx = cv.get_selection_idx();
        if (idx != -1) {
          editor.needle.area.splice(idx, 1);
          cv.delete_shape_idx(idx);
          editor.UpdateTextArea();
        }
      } else if (e.keyCode == KeyEvent.DOM_VK_INSERT) {
        var a = {xpos: 0, ypos: 0, width: MINSIZE, height: MINSIZE, type: 'match'};
        cv.addShape(NeedleEditor.ShapeFromArea(a));
        editor.needle.area.push(a);
        editor.UpdateTextArea();
      }
    },
    true
  );
  cv.shape_changed_cb = function (shape) {
    var idx = cv.get_shape_idx(shape);
    var a = editor.needle.area[idx];
    var click_point = shape.click_point;
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
    var a = {xpos: x, ypos: y, width: MINSIZE, height: MINSIZE, type: 'match'};
    var shape = NeedleEditor.ShapeFromArea(a);
    cv.addShape(shape);
    editor.needle.area.push(a);
    editor.UpdateTextArea();
    return shape;
  };
  var areaSpecificButtons = $('#change-match, #change-margin, #toggle-click-coordinates');
  $(cv).on('shape.selected', function () {
    areaSpecificButtons.removeClass('disabled').removeAttr('disabled');
    updateToggleClickCoordinatesButton(editor.currentClickCoordinates());
  });
  $(cv).on('shape.unselected', function () {
    areaSpecificButtons.addClass('disabled').attr('disabled', 1);
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
  var input = document.createElement('input');
  input.type = 'checkbox';
  input.value = tag;
  input.checked = checked;
  input.id = 'tagInput' + this.tags.childNodes.length;
  var editor = this;
  input.addEventListener('click', function (e, f) {
    editor.changeTag(e.target.value, e.target.checked);
  });
  var div = document.createElement('div');
  var label = document.createElement('label');
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
  var editor = this;
  // not yet there
  if (!editor.cv) return false;

  jQuery.each(editor.needle.area, function (index, area) {
    editor.cv.addShape(NeedleEditor.ShapeFromArea(area));
  });
  return true;
};

NeedleEditor.prototype.LoadBackground = function (url) {
  var editor = this;
  var image = new Image();
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
  var editor = this;
  var cv = this.cv;
  var x = new XMLHttpRequest();
  x.onreadystatechange = function () {
    if (this.readyState != 4) {
      return;
    }
    if (this.status == 200) {
      editor.needle = JSON.parse(this.responseText);
      editor.init();
    } else if (this.status == 404) {
      editor.needle = JSON.parse('{ "area": [], "tags": [] , "properties": [] }');
      editor.init();
    } else {
      var ctx = editor.canvas.getContext('2d');
      ctx.font = '20pt Verdana';
      ctx.fillText('Failed to load Needle, Code ' + this.status, 10, 50);
    }
  };
  x.open('GET', url, true);
  x.send();
};

NeedleEditor.prototype.LoadAreas = function (areas) {
  var editor = this;

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
  var tags = this.needle.tags;
  if (enabled) {
    tags.push(name);
    tags.sort();
  } else {
    var idx = tags.indexOf(name);
    tags.splice(idx, 1);
  }
  this.UpdateTextArea();
};

NeedleEditor.prototype.changeProperty = function (name, enabled) {
  var properties = this.needle.properties;

  if (enabled) {
    properties.push({name: name});
  } else {
    for (var i = 0; i < properties.length; i++) {
      if (properties[i].name === name) {
        properties.splice(i, 1);
        break;
      }
    }
  }
  this.UpdateTextArea();
};

NeedleEditor.prototype.changeWorkaroundDesc = function (value) {
  var properties = this.needle.properties;
  for (var i = 0; i < properties.length; i++) {
    if (properties[i].name === 'workaround') {
      properties[i].value = value;
      break;
    }
  }
  this.UpdateTextArea();
};

NeedleEditor.prototype.selection = function () {
  var cv = this.cv;
  var idx = cv.get_selection_idx();
  var areas = this.needle.area;
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
  var selectedArea = this.selectedArea();
  if (!selectedArea) {
    return;
  }
  selectedArea.margin = parseInt(value);
  this.UpdateTextArea();
};

NeedleEditor.prototype.setMatch = function (value) {
  var selectedArea = this.selectedArea();
  if (!selectedArea) {
    return;
  }
  selectedArea.match = parseFloat(value);
  this.UpdateTextArea();
};

NeedleEditor.prototype.currentClickCoordinates = function () {
  var selectedArea = this.selectedArea();
  return selectedArea ? selectedArea.click_point : undefined;
};

NeedleEditor.prototype.toggleClickCoordinates = function () {
  var selection = this.selection();
  var selectedArea = selection.area;
  var selectedShape = selection.shape;
  if (!selectedArea || !selectedShape) {
    return;
  }

  var clickPoint = selectedArea.click_point;
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
    var selectedIndex = selection.index;
    var areas = this.needle.area;
    var shapes = this.cv.shapes;
    for (var i = 0; i != areas.length; ++i) {
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
  var needle = window.needles[$('#image_select option:selected').val()];
  nEditor.LoadBackground(needle.imageurl);
  $('#needleeditor_image').val(needle.imagename);
  $('#needleeditor_imagedistri').val(needle.imagedistri);
  $('#needleeditor_imageversion').val(needle.imageversion);
  $('#needleeditor_imagedir').val(needle.imagedir);
}

function loadTagsAndName() {
  var needle = window.needles[$('#tags_select option:selected').val()];
  var tags = needle.tags;
  $('#needleeditor_tags')
    .find('input')
    .each(function () {
      $(this).prop('checked', tags.indexOf($(this).val()) !== -1);
    });

  var workaroundFlag = 0;
  for (var i = 0; i < needle.properties.length; i++) {
    if (needle.properties[i].name === 'workaround') {
      $('#property_workaround').prop('checked', true);
      if (needle.properties[i].value === undefined) {
        $('#input_workaround_desc').val('');
      } else {
        $('#input_workaround_desc').val(needle.properties[i].value);
      }
      $('#workaround_reason').show();
      workaroundFlag = 1;
      break;
    }
  }
  if (workaroundFlag === 0) {
    $('#property_workaround').prop('checked', false);
    $('#input_workaround_desc').val('');
    $('#workaround_reason').hide();
  }

  $('#needleeditor_name').val(needle.suggested_name);
  $('#area_select').val(needle.name);
  loadAreas();
  nEditor.LoadTags(tags);
  nEditor.LoadProperty(needle.properties);
  nEditor.UpdateCommitMessage(needle.suggested_name);
}

function loadAreas() {
  var needle = window.needles[$('#area_select option:selected').val()];
  if ($('#take_matches').prop('checked')) {
    // merge exclude areas into matches if not done yet
    var matches = needle.matches;
    if (!matches.hasIncludes) {
      $.each(needle.area, function (index, area) {
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
  var input = $('#newtag');
  var checkbox = nEditor.AddTag(input.val(), false);
  input.val('');
  input.keyup();
  checkbox.click();
  return false;
}

function setMargin() {
  nEditor.setMargin($('#margin').val());
}

function setMatch() {
  nEditor.setMatch($('#match').val());
}

function toggleClickCoordinates() {
  updateToggleClickCoordinatesButton(nEditor.toggleClickCoordinates());
}

function updateToggleClickCoordinatesButton(hasClickCoorinates) {
  if (hasClickCoorinates) {
    $('#toggle-click-coordinates-verb').text('Remove');
  } else {
    $('#toggle-click-coordinates-verb').text('Add');
  }
}

function saveNeedle(overwrite) {
  var form = document.getElementById('save_needle_form');
  var errors = [];
  var needle_name = document.getElementById('needleeditor_name').value;
  if (!/-\d{8}$/.test(needle_name)) {
    errors.push('No valid timestamp');
  }
  var tagSelection = window.needles[$('#tags_select').val()];
  if (!tagSelection.tags.length) {
    errors.push('No tags specified.');
  }
  var areaSelection = window.needles[$('#area_select').val()];
  var takeMatches = $('#take_matches').prop('checked');
  if ((!takeMatches && !areaSelection.area.length) || (takeMatches && !areaSelection.matches.length)) {
    errors.push('No areas defined.');
  }
  if (errors.length) {
    addFlash('danger', '<strong>Unable to save needle:</strong><ul><li>' + errors.join('</li><li>') + '</li></ul>');
    return false;
  }

  if (!overwrite && $('#property_workaround').prop('checked') && !$('#input_workaround_desc').val()) {
    var confirmMessage =
      'You set the workaround property for this needle without a description. Are you sure you want to save without a description?';
    if (!confirm(confirmMessage)) {
      return false;
    }
  }

  $('#needle_editor_save_buttons').hide();
  $('#needle_editor_loading_indication').show();

  document.getElementById('save').disabled = true;
  document.getElementById('needleeditor_overwrite').value = overwrite ? '1' : '0';

  fetchWithCSRF(form.action, {method: 'POST', body: new FormData(form)})
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
      $('#needle_editor_loading_indication').hide();
      $('#needle_editor_save_buttons').show();
      document.getElementById('save').disabled = false;
    });
  if (window.overwriteModal) {
    window.overwriteModal.hide();
  }
  return false;
}

var nEditor;

function submitMargin() {
  setMargin();
  $('#change-margin-form').modal('hide');
  return false;
}

function submitMatch() {
  setMatch();
  $('#change-match-form').modal('hide');
  return false;
}

function setup_needle_editor(imageurl, default_needle) {
  nEditor = new NeedleEditor(imageurl, default_needle);

  $('.tag_checkbox').click(function () {
    nEditor.changeTag(this.value, this.checked);
  });

  $('#tag_add_button').click(addTag);
  $('#newtag').keypress(function (event) {
    if (event.keyCode == 13) return addTag();
    return true;
  });

  $('#property_workaround').click(function () {
    nEditor.changeProperty(this.name, this.checked);
    $('#workaround_reason').toggle(this.checked);
  });

  $('#input_workaround_desc').blur(function () {
    nEditor.changeWorkaroundDesc(this.value);
  });

  $('#image_select').change(loadBackground);
  // load default
  loadBackground();
  $('#tags_select').change(loadTagsAndName);
  loadTagsAndName();
  $('#area_select').change(loadAreas);
  $('#take_matches').change(loadAreas);
  $('#match_form').submit(submitMatch);
  $('#margin_form').submit(submitMargin);

  $('#change-margin-form').on('show.bs.modal', function () {
    var idx = nEditor.cv.get_selection_idx();
    if (idx === -1) {
      if (!this.needle.area.length) {
        return;
      }
      idx = 0;
    }
    $('#margin').val(nEditor.needle.area[idx].margin || 50);
  });
  $('#change-match-form').on('show.bs.modal', function () {
    var idx = nEditor.cv.get_selection_idx();
    if (idx == -1) {
      if (!this.needle.area.length) {
        return;
      }
      idx = 0;
    }
    $('#match').val(nEditor.needle.area[idx].match || 96);
  });

  $('#review_json').popover({
    trigger: 'focus',
    content: function () {
      return $('#needleeditor_textarea').val();
    },
    template:
      '<div class="popover" role="tooltip"><div class="arrow"></div><h3 class="popover-header"></h3><pre class="popover-body"></pre></div>'
  });

  // invoke "saveNeedle()" when the "Save" button or the "Overrite" button is clicked
  document.getElementById('save_needle_form').onsubmit = saveNeedle.bind(undefined, false);
  document.getElementById('modal-overwrite-confirm').onclick = saveNeedle.bind(undefined, true);

  $('#newtag').bind('propertychange change click keyup input paste', function () {
    var invalid = !this.value.length || !this.validity.valid;
    $('#tag_add_button').prop('disabled', invalid);
  });
  $(document).on('click', '.restart-link', function (event) {
    restartJob(event.target.dataset.url, window.jobId);
    event.preventDefault();
  });
}

// Now go make something amazing!
