// Two possible ways of calling it:
// 1) new NeedleEditor(baseurl)
// 2) new NeedleEditor(background, needlestring)
function NeedleEditor() {
  var baseurl;
  var background, needlestring;

  if (arguments.length == 1) {
    baseurl = arguments[0];
  } else {
    background = arguments[0];
    needlestring = arguments[1];
  }

  this.textarea = document.getElementById("needleeditor_textarea");
  this.tags = document.getElementById("needleeditor_tags");
  this.canvas = document.getElementById("needleeditor_canvas");
  if (!this.canvas) {
    alert("missing canvas element "+canvasid);
    return;
  }
  this.bgImage = null;
  this.cv = null;
  if (needlestring) {
    this.LoadBackground(background);
    this.needle = JSON.parse(needlestring);
  } else {
    this.LoadBackground(baseurl + ".png");
    this.needle = null;
    this.LoadNeedle(baseurl + ".json");
  }
  this.init();
}

NeedleEditor.prototype.init = function() {
  if (!this.bgImage || !this.needle) {
    return;
  }

  var editor = this;

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
  }
  cv.new_shape_cb = function(x, y) {
    var a = { 'xpos': x, 'ypos': y, 'width': MINSIZE, 'height': MINSIZE, 'type': 'match' };
    var shape = NeedleEditor.ShapeFromArea(a);
    cv.addShape(shape);
    editor.needle.area.push(a);
    editor.UpdateTextArea();
    return shape;
  }
}

NeedleEditor.prototype.UpdateTextArea = function() {
  if (this.textarea) {
    this.textarea.value = JSON.stringify(this.needle, null, "  ");
  }
}

NeedleEditor.prototype.AddTag = function(tag, checked) {
  var label = document.createElement('label');
  var input = document.createElement('input');
  var editor = this;
  input.type = "checkbox";
  input.value = tag;
  input.checked = checked;
  input.addEventListener("click", function(e, f) {
    editor.changeTag(e.target.value, e.target.checked);
  });
  this.tags.appendChild(label);
  label.appendChild(input);
  label.appendChild(document.createTextNode(tag));
  label.appendChild(document.createElement('br'));
  return input;
}

NeedleEditor.nexttype = function(type) {
    if (type == 'match') {
      return 'exclude';
    } else if (type == 'exclude') {
      return 'ocr';
    }
    return 'match';
}

NeedleEditor.ShapeFromArea = function(a) {
  return new Shape(a['xpos'], a['ypos'], a['width'], a['height'], NeedleEditor.areacolor(a['type']));
}

NeedleEditor.prototype.DrawAreas = function() {
  this.needle['area'].forEach(function(area) {
    this.cv.addShape(NeedleEditor.ShapeFromArea(area));
  }.bind(this));
  return true;
}

NeedleEditor.prototype.LoadBackground = function(url) {
  var editor = this;
  var cv = this.cv;
  var image = new Image();
  image.src = url;
  image.onload = function() {
    editor.bgImage = image;
    if (cv) {
      cv.set_bgImage(editor.bgImage);
    } else {
      editor.init();
    }
  }
}

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
  }
  x.open("GET", url, true);
  x.send();
}

NeedleEditor.prototype.LoadAreas = function(areas) {
  var editor = this;
  var cv = this.cv;

  editor.needle["area"] = areas;
  cv.delete_shapes();
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

// If you dont want to use <body onLoad='init()'>
// You could uncomment this init() reference and place the script reference inside the body tag
//init();

/*
function init() {
  var n = new NeedleEditor("canvas1", "inst-welcome");
}

window.addEventListener('load', init, true);
*/

// Now go make something amazing!
