function NeedleEditor (needle) {
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
  const editor = this;

  if (this.cv) {
    this.cv.set_bgImage(this.bgImage);
    return;
  }

  const cv = this.cv = new CanvasState(this.canvas);

  cv.set_bgImage(this.bgImage);

  if (this.tags) {
    // If tags is empty, we must populate it with a checkbox for every tag
    if (this.tags.getElementsByTagName('input').length == 0) {
      this.needle.tags.forEach(function (tag) {
        this.AddTag(tag, true);
      }.bind(this));
      // If the checkboxes are already there, we simply check them all
    } else {
      const inputs = this.tags.getElementsByTagName('input');
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
  cv.canvas.addEventListener('dblclick', function (e) {
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
  }, true);

  cv.canvas.addEventListener('keyup', function (e) {
    // console.warn("key %d", e.keyCode);
    if (e.keyCode == KeyEvent.DOM_VK_DELETE) {
      const idx = cv.get_selection_idx();
      if (idx != -1) {
        editor.needle.area.splice(idx, 1);
        cv.delete_shape_idx(idx);
        editor.UpdateTextArea();
      }
    } else if (e.keyCode == KeyEvent.DOM_VK_INSERT) {
      const a = { xpos: 0, ypos: 0, width: MINSIZE, height: MINSIZE, type: 'match' };
      cv.addShape(NeedleEditor.ShapeFromArea(a));
      editor.needle.area.push(a);
      editor.UpdateTextArea();
    }
  }, true);
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
    const a = { xpos: x, ypos: y, width: MINSIZE, height: MINSIZE, type: 'match' };
    const shape = NeedleEditor.ShapeFromArea(a);
    cv.addShape(shape);
    editor.needle.area.push(a);
    editor.UpdateTextArea();
    return shape;
  };
  const areaSpecificButtons = $('#change-match, #change-margin, #toggle-click-coordinates');
  $(cv).on('shape.selected', function () {
    areaSpecificButtons.removeClass('disabled').removeAttr('disabled');
    updateToggleClickCoordinatesButton(editor.currentClickCoordinates());
  });
  $(cv).on('shape.unselected', function () {
    areaSpecificButtons.addClass('disabled').attr('disabled', 1);
  });

  document.getElementById('needleeditor_name').onchange = function () { editor.UpdateCommitMessage(this.value); };
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
  if (!editor.cv) { return false; }

  jQuery.each(editor.needle.area, function (index, area) {
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
  const editor = this;
  const cv = this.cv;
  const x = new XMLHttpRequest();
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
      const ctx = editor.canvas.getContext('2d');
      ctx.font = '20pt Verdana';
      ctx.fillText('Failed to load Needle, Code ' + this.status, 10, 50);
    }
  };
  x.open('GET', url, true);
  x.send();
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
    properties.push({ name: name });
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

function loadBackground () {
  const needle = window.needles[$('#image_select option:selected').val()];
  nEditor.LoadBackground(needle.imageurl);
  $('#needleeditor_image').val(needle.imagename);
  $('#needleeditor_imagedistri').val(needle.imagedistri);
  $('#needleeditor_imageversion').val(needle.imageversion);
  $('#needleeditor_imagedir').val(needle.imagedir);
}

function loadTagsAndName () {
  const needle = window.needles[$('#tags_select option:selected').val()];
  const tags = needle.tags;
  $('#needleeditor_tags').find('input').each(function () {
    $(this).prop('checked', tags.indexOf($(this).val()) !== -1);
  });

  let workaroundFlag = 0;
  for (let i = 0; i < needle.properties.length; i++) {
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

function loadAreas () {
  const needle = window.needles[$('#area_select option:selected').val()];
  if ($('#take_matches').prop('checked')) {
    // merge exclude areas into matches if not done yet
    const matches = needle.matches;
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

function addTag () {
  const input = $('#newtag');
  const checkbox = nEditor.AddTag(input.val(), false);
  input.val('');
  input.keyup();
  checkbox.click();
  return false;
}

function setMargin () {
  nEditor.setMargin($('#margin').val());
}

function setMatch () {
  nEditor.setMatch($('#match').val());
}

function toggleClickCoordinates () {
  updateToggleClickCoordinatesButton(nEditor.toggleClickCoordinates());
}

function updateToggleClickCoordinatesButton (hasClickCoorinates) {
  if (hasClickCoorinates) {
    $('#toggle-click-coordinates-verb').text('Remove');
  } else {
    $('#toggle-click-coordinates-verb').text('Add');
  }
}

function reactToSaveNeedle (data) {
  $('#needle_editor_loading_indication').hide();
  $('#needle_editor_save_buttons').show();

  const failed = data.status !== 200 ||
        !data.responseJSON ||
        (!data.responseJSON.success && !data.responseJSON.requires_overwrite);
  const defaultErrorMessage = '<strong>Fatal error when saving needle.</strong>';
  if (failed && (!data.responseJSON || typeof data.responseJSON.error !== 'string')) {
    data = { error: defaultErrorMessage };
  } else {
    data = data.responseJSON;
  }

  let successMessage = data.success;
  const requiresOverwrite = data.requires_overwrite;
  let errorMessage = data.error;
  if (successMessage) {
    // add note to go back or restart
    if (data.developer_session_job_id) {
      successMessage += " - <a href='/tests/" + data.developer_session_job_id + "#live'>back to live view</a>";
    } else if (data.restart) {
      successMessage += " - <a href='#' data-url='" + data.restart + "' class='restart-link'>restart job</a>";
    }
    addFlash('info', successMessage);
  } else if (errorMessage) {
    // add context to the error message unless it starts with an HTML tag (and is therefore assumed to be
    // already nicely formatted)
    if (errorMessage.indexOf('<') !== 0) {
      errorMessage = [defaultErrorMessage, errorMessage].join('<br>');
    }
    addFlash('danger', errorMessage);
  } else if (requiresOverwrite) {
    delete data.requires_overwrite;
    $('#modal-overwrite .modal-title').text('Sure to overwrite ' + data.needlename + '?');
    $('#modal-overwrite').data('formdata', data);
    $('#modal-overwrite').modal();
  }

  $('#save').prop('disabled', false);
}

function saveNeedle (e) {
  const form = $('#save_needle_form');
  const errors = [];
  const tagSelection = window.needles[$('#tags_select').val()];
  if (!tagSelection.tags.length) {
    errors.push('No tags specified.');
  }
  const areaSelection = window.needles[$('#area_select').val()];
  const takeMatches = $('#take_matches').prop('checked');
  if ((!takeMatches && !areaSelection.area.length) || (takeMatches && !areaSelection.matches.length)) {
    errors.push('No areas defined.');
  }
  if (errors.length) {
    addFlash('danger', '<strong>Unable to save needle:</strong><ul><li>' + errors.join('</li><li>') + '</li></ul>');
    return false;
  }

  if ($('#property_workaround').prop('checked') && !$('#input_workaround_desc').val()) {
    const confirmMessage = 'You set the workaround property for this needle without a description. Are you sure you want to save without a description?';
    if (!confirm(confirmMessage)) {
      return false;
    }
  }

  $('#save').prop('disabled', true);
  $('#needle_editor_save_buttons').hide();
  $('#needle_editor_loading_indication').show();
  $.ajax({
    type: 'POST',
    url: form.attr('action'),
    data: form.serialize(),
    complete: reactToSaveNeedle
  });
  return false;
}

// eslint-disable-next-line
var nEditor;

function submitMargin () {
  setMargin();
  $('#change-margin-form').modal('hide');
  return false;
}

function submitMatch () {
  setMatch();
  $('#change-match-form').modal('hide');
  return false;
}

function setup_needle_editor (imageurl, default_needle) {
  nEditor = new NeedleEditor(imageurl, default_needle);

  $('.tag_checkbox').click(function () {
    nEditor.changeTag(this.value, this.checked);
  });

  $('#tag_add_button').click(addTag);
  $('#newtag').keypress(function (event) {
    if (event.keyCode == 13) { return addTag(); }
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
    let idx = nEditor.cv.get_selection_idx();
    if (idx === -1) {
      if (!this.needle.area.length) {
        return;
      }
      idx = 0;
    }
    $('#margin').val(nEditor.needle.area[idx].margin || 50);
  });
  $('#change-match-form').on('show.bs.modal', function () {
    let idx = nEditor.cv.get_selection_idx();
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
    template: '<div class="popover" role="tooltip"><div class="arrow"></div><h3 class="popover-header"></h3><pre class="popover-body"></pre></div>'
  });

  $('#modal-overwrite').on('hidden.bs.modal', function () { $('#save').prop('disabled', false); });
  $('#modal-overwrite-confirm').click(function () {
    const data = $('#modal-overwrite').data('formdata');
    data.overwrite = 1;
    $.ajax({
      type: 'POST',
      url: $('#save_needle_form').attr('action'),
      data: data,
      complete: function (data2, status) {
        $('#modal-overwrite').modal('hide');
        reactToSaveNeedle(data2);
      }
    });
    return false;
  });

  $('#newtag').bind(
    'propertychange change click keyup input paste',
    function () {
      const invalid = !this.value.length || !this.validity.valid;
      $('#tag_add_button').prop('disabled', invalid);
    });

  $('#save_needle_form').submit(saveNeedle);
  $(document).on('click', '.restart-link', function (event) {
    restartJob(event.target.dataset.url, window.jobId);
    event.preventDefault();
  });
}

// Now go make something amazing!
