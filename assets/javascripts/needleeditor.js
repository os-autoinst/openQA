function NeedleEditor(needle) {
  this.textarea = document.getElementById("needleeditor_textarea");
  this.tags = document.getElementById("needleeditor_tags");
  this.canvas = document.getElementById("needleeditor_canvas");
  if (!this.canvas) {
    alert("missing canvas element "+canvasid);
    return;
  }
  this.bgImage = null;
  this.cv = null;
  this.needle = needle;
}

NeedleEditor.prototype.init = function() {
  var editor = this;

  if (this.cv) {
    this.cv.set_bgImage(this.bgImage);
    return;
  }

  var cv = this.cv = new CanvasState(this.canvas);

  cv.set_bgImage(this.bgImage);

  if (this.tags) {
    // If tags is empty, we must populate it with a checkbox for every tag
    if (this.tags.getElementsByTagName('input').length == 0) {
      this.needle['tags'].forEach(function(tag) {
        this.AddTag(tag, true);
      }.bind(this));
      // If the checkboxes are already there, we simply check them all
    } else {
      var inputs = this.tags.getElementsByTagName('input');
      for (var i = 0; i < inputs.length; i++) {
        if (this.needle['tags'].indexOf(inputs[i].value) >= 0) {
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
  cv.canvas.addEventListener('dblclick', function(e) {
    var idx = cv.get_selection_idx();
    if (idx == -1) {
      return;
    }
    var shape = cv.get_shape(idx);
    var a = editor.needle.area[idx];
    a['type'] = NeedleEditor.nexttype(a['type']);
    shape.fill = NeedleEditor.areacolor(a['type']);
    editor.UpdateTextArea();
    cv.redraw();
  }, true);

  cv.canvas.addEventListener('keyup', function(e) {
    //console.warn("key %d", e.keyCode);
    if (e.keyCode == KeyEvent.DOM_VK_DELETE) {
      var idx = cv.get_selection_idx();
      if (idx != -1) {
        editor.needle['area'].splice(idx, 1);
        cv.delete_shape_idx(idx);
        editor.UpdateTextArea();
      }
    } else if (e.keyCode == KeyEvent.DOM_VK_INSERT) {
      var a = { 'xpos': 0, 'ypos': 0, 'width': MINSIZE, 'height': MINSIZE, 'type': 'match' };
      cv.addShape(NeedleEditor.ShapeFromArea(a));
      editor.needle.area.push(a);
      editor.UpdateTextArea();
    }
  }, true);
  cv.shape_changed_cb = function(shape) {
    var idx = cv.get_shape_idx(shape);
    var a = editor.needle.area[idx];
    a['xpos'] = shape.x;
    a['ypos'] = shape.y;
    a['width'] = shape.w;
    a['height'] = shape.h;
    editor.UpdateTextArea();
  };
  cv.new_shape_cb = function(x, y) {
    var a = { 'xpos': x, 'ypos': y, 'width': MINSIZE, 'height': MINSIZE, 'type': 'match' };
    var shape = NeedleEditor.ShapeFromArea(a);
    cv.addShape(shape);
    editor.needle.area.push(a);
    editor.UpdateTextArea();
    return shape;
  };
  $(cv).on('shape.selected', function() {
    $('#change-match').removeClass('disabled').removeAttr('disabled');
    $('#change-margin').removeClass('disabled').removeAttr('disabled');
  });
  $(cv).on('shape.unselected', function() {
    $('#change-match').addClass('disabled').attr('disabled', 1);
    $('#change-margin').addClass('disabled').attr('disabled', 1);
  });
};

NeedleEditor.prototype.UpdateTextArea = function() {
  if (this.textarea) {
    this.textarea.value = JSON.stringify(this.needle, null, "  ");
  }
}

NeedleEditor.prototype.AddTag = function(tag, checked) {
  var input = document.createElement('input');
  input.type = "checkbox";
  input.value = tag;
  input.checked = checked;
  input.id = 'tagInput' + this.tags.childNodes.length;
  var editor = this;
  input.addEventListener("click", function(e, f) {
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
}

NeedleEditor.nexttype = function(type) {
  if (type == 'match') {
    return 'exclude';
  } else if (type == 'exclude') {
    return 'ocr';
  }
  return 'match';
};

NeedleEditor.ShapeFromArea = function(a) {
  return new Shape(a['xpos'], a['ypos'], a['width'], a['height'], NeedleEditor.areacolor(a['type']));
};

NeedleEditor.prototype.DrawAreas = function() {
  var editor = this;
  // not yet there 
  if (!editor.cv)
    return false;
  
  jQuery.each(editor.needle['area'], function(index, area) {
    editor.cv.addShape(NeedleEditor.ShapeFromArea(area));
  });
  return true;
};

NeedleEditor.prototype.LoadBackground = function(url) {
  var editor = this;
  var image = new Image();
  image.src = url;
  image.onload = function() {
    editor.bgImage = image;
    editor.init();
  };
};

NeedleEditor.prototype.LoadTags = function(tags) {
  this.needle['tags'] = tags;
  this.UpdateTextArea();
}

NeedleEditor.prototype.LoadNeedle = function(url) {
  var editor = this;
  var cv = this.cv;
  var x = new XMLHttpRequest();
  x.onreadystatechange = function() {
    if (this.readyState != 4) {
      return;
    }
    if (this.status == 200)
    {
      var needle = JSON.parse(this.responseText);
      editor.needle = needle;
      editor.init();
    } else if (this.status == 404)
    {
      var needle = JSON.parse('{ "area": [], "tags": [] , "properties": [] }');
      editor.needle = needle;
      editor.init();
    } else {
      var ctx = editor.canvas.getContext("2d");
      ctx.font = "20pt Verdana";
      ctx.fillText("Failed to load Needle, Code " + this.status, 10, 50);
    }
  };
  x.open("GET", url, true);
  x.send();
}

NeedleEditor.prototype.LoadAreas = function(areas) {
  var editor = this;
  
  editor.needle["area"] = areas;
  if (this.cv) {
    this.cv.delete_shapes();
  }
  this.DrawAreas();
  this.UpdateTextArea();
}

NeedleEditor.areacolors = {
  'match':   'rgba(  0, 255, 0, .5)',
  'exclude': 'rgba(255,   0, 0, .5)',
  'ocr':     'rgba(255, 255, 0, .5)',
};

NeedleEditor.areacolor = function(type) {
  if (type in NeedleEditor.areacolors) {
    return NeedleEditor.areacolors[type];
  }
  return "pink";
}

NeedleEditor.prototype.changeTag = function(name, enabled) {
  var tags = this.needle['tags'];
  if (enabled) {
    tags.push(name);
    tags.sort();
  } else {
    var idx = tags.indexOf(name);
    tags.splice(idx, 1);
  }
  this.UpdateTextArea();
}

NeedleEditor.prototype.changeProperty = function(name, enabled) {
  var properties = this.needle['properties'];
  if (enabled) {
    properties.push(name);
    properties.sort();
  } else {
    var idx = properties.indexOf(name);
    properties.splice(idx, 1);
  }
  this.UpdateTextArea();
}

NeedleEditor.prototype.setMargin = function(value) {
  var idx = this.cv.get_selection_idx();
  if (idx == -1) {
    if (!this.needle["area"].length) {
      return;
    }
    idx = 0;
  }
  this.needle['area'][idx].margin = parseInt(value);
  this.UpdateTextArea();
}

NeedleEditor.prototype.setMatch = function(value) {
  var idx = this.cv.get_selection_idx();
  if (idx == -1) {
    if (!this.needle["area"].length) {
      return;
    }
    idx = 0;
  }
  
  this.needle['area'][idx].match = parseFloat(value);
  this.UpdateTextArea();
}

function loadBackground() {
  var needle = window.needles[$('#image_select option:selected').val()];
  nEditor.LoadBackground(needle['imageurl']);
  $("#needleeditor_image").val(needle['imagename']);
  $("#needleeditor_imagedistri").val(needle['imagedistri']);
  $("#needleeditor_imageversion").val(needle['imageversion']);
  $("#needleeditor_imagedir").val(needle['imagedir']);
}

function loadTagsAndName() {
  var needle = window.needles[$('#tags_select option:selected').val()];
  var tags = needle['tags'];
  $("#needleeditor_tags").find('input').each(function() {
    $(this).prop('checked', tags.indexOf($(this).val()) != -1);
  });
  $("#property_workaround").prop('checked', $.inArray('workaround', needle.properties) !== -1);
  $("#needleeditor_name").val(needle['suggested_name']);
  $("#area_select").val(needle['name']);
  loadAreas();
  nEditor.LoadTags(tags);
}

function loadAreas() {
  var needle = window.needles[$('#area_select option:selected').val()];
  if ($('#take_matches').prop('checked')) {
    nEditor.LoadAreas(needle['matches']);
  } else {
    nEditor.LoadAreas(needle['area']);
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

function reactToSaveNeedle(data) {
  if (data.status != 200 && (!data.responseJSON || !data.responseJSON.error)) {
    data = {error: "Fatal error on saving needle"};
  } else {
    data = data.responseJSON;
  }
  if (data.info) {
    var info = data.info;
    if (data.interactive_job) {
      info += " - <a href='/tests/" + data.interactive_job + "#live'>back to live view</a>";
    } else if (data.restart) {
      info += " - <a href='#' data-url='" + data.restart + "' class='restart-link'>restart job</a>";
    }
    addFlash('info', info);
    $('#save').prop('disabled', false);
    return;
  }
  if (data.error) {
    addFlash('warning', data.error);
    $('#save').prop('disabled', false);
    return;
  }
  if (data.requires_overwrite) {
    delete data.requires_overwrite;
    $('#modal-overwrite .modal-title').text("Sure to overwrite " + data.needlename + "?");
    $('#modal-overwrite').data('formdata', data);
    $('#modal-overwrite').modal();
  } else {
    $('#save').prop('disabled', false);
  }
}

function saveNeedle(e) {
  var form = $("#save_needle_form");
  var errors = [];
  var selection = window.needles[$('#tags_select').val()];
  var takeMatches = $('#take_matches').prop('checked');
  if(!selection.tags.length) {
      errors.push('No tags specified.');
  }
  if((!takeMatches && !selection.area.length)
      || (takeMatches && !selection.matches.length)) {
      errors.push('No areas defined.');
  }
  if(errors.length) {
      addFlash('danger', '<strong>Unable to save needle:</strong><ul><li>' + errors.join('</li><li>') + '</li></ul>');
      return false;
  }
  $('#save').prop('disabled', true);
  $.ajax({
    type: "POST",
    url: form.attr('action'),
    data: form.serialize(),
    complete: reactToSaveNeedle
  });
  return false;
}

function restartJobSuccess(data, res, xhr) {
  window.location.replace(xhr.responseJSON.test_url);
}

// restart-link in flash message
function restartJob(event) {
  $.ajax({
    type: 'POST',
    url: $(this).data('url'),
    success: restartJobSuccess
  });
  event.preventDefault();
}

var nEditor;

function setup_needle_editor(imageurl, default_needle)
{
  nEditor = new NeedleEditor(imageurl, default_needle);

  $('.tag_checkbox').click(function() {
    nEditor.changeTag(this.value, this.checked);
  });

  $('#tag_add_button').click(addTag);
  $('#newtag').keypress(function(event) {
    if (event.keyCode==13)
      return addTag();
    return true;
  });
  
  $('#property_workaround').click(function() { nEditor.changeProperty(this.name, this.checked); });

  $('#image_select').change(loadBackground);
  // load default
  loadBackground();
  $('#tags_select').change(loadTagsAndName);
  loadTagsAndName();
  $('#area_select').change(loadAreas);
  $('#take_matches').change(loadAreas);

  $('#set_margin').click(function() { setMargin(); $('#change-margin-form').modal('hide'); } );
  $('#set_match').click(function() { setMatch(); $('#change-match-form').modal('hide'); } );
  $('#change-margin-form').on('show.bs.modal', function() {
    var idx = nEditor.cv.get_selection_idx();
    if (idx == -1) {
      if (!this.needle["area"].length) {
        return;
      }
      idx = 0;
    }
    $('#margin').val(nEditor.needle['area'][idx].margin || 50);
  });
  $('#change-match-form').on('show.bs.modal', function() {
    var idx = nEditor.cv.get_selection_idx();
    if (idx == -1) {
      if (!this.needle["area"].length) {
        return;
      }
      idx = 0;
    }
    $('#match').val(nEditor.needle['area'][idx].match || 96);
  });
  
  $('#review_json').popover({
    trigger: 'focus',
    content: function() { return $('#needleeditor_textarea').val(); },
    template: '<div class="popover" role="tooltip"><div class="arrow"></div><h3 class="popover-title"></h3><pre class="popover-content"></pre></div>'
  } );

  $('#modal-overwrite').on('hidden.bs.modal', function() { $('#save').prop('disabled', false); });
  $('#modal-overwrite-confirm').click(function() {
    var data = $('#modal-overwrite').data('formdata');
    data.overwrite = 1;
    $.ajax({
      type: "POST",
      url: $("#save_needle_form").attr('action'),
      data: data,
      complete: function(data2, status) { $('#modal-overwrite').modal('hide'); reactToSaveNeedle(data2); }
    });
    return false;
  });

  $('#newtag').bind(
      "propertychange change click keyup input paste",
      function() { $('#tag_add_button').prop('disabled', !this.value.length); }
  );

  $('#save_needle_form').submit(saveNeedle);
  $(document).on('click', '.restart-link', restartJob);
}


// Now go make something amazing!
