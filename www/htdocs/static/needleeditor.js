function NeedleEditor(baseurl) {
  this.textarea = document.getElementById("needleeditor_textarea");
  this.tags = document.getElementById("needleeditor_tags");
  this.canvas = document.getElementById("needleeditor_canvas");
  if (!this.canvas) {
    alert("missing canvas element "+canvasid);
    return;
  }
  this.LoadBackground(baseurl + ".png");
  this.LoadNeedle(baseurl + ".json");
  this.needle = null;
  this.bgImage = null;
  this.cv = null;
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
    for (var i in this.needle['tags']) {
      var tag = this.needle['tags'][i]
      console.log("tag " + tag);
      var label = document.createElement('label');
      var input = document.createElement('input');
      input.type = "checkbox";
      input.value = tag;
      input.checked = true;
      input.addEventListener("click", function(e, f) {
	editor.changeTag(e.target.value, e.target.checked);
      });

      this.tags.appendChild(label);
      label.appendChild(input);
      label.appendChild(document.createTextNode(tag));
      label.appendChild(document.createElement('br'));
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
  for (var i in this.needle['area']) {
    var a = this.needle['area'][i];
    this.cv.addShape(NeedleEditor.ShapeFromArea(a));
  }
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
      var needle = JSON.parse('{ "area": [], "tags": [] }');
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

  editor.needle["area"] = JSON.parse(areas);
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
