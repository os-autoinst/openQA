// By Simon Sarris
// www.simonsarris.com
// sarris@acm.org
// December 2011
//
// Updated April 2013 by Ludwig Nussel
//
// Free to use and distribute at will
// So long as you are nice to people, etc


// http://stackoverflow.com/questions/217957/how-to-print-debug-messages-in-the-google-chrome-javascript-console
if (!window.console) console = {};
console.log = console.log || function(){};
console.warn = console.warn || function(){};
console.error = console.error || function(){};
console.info = console.info || function(){};

var MINSIZE = 10;

// Constructor for Shape objects to hold data for all drawn objects.
// For now they will just be defined as rectangles.
function Shape(x, y, w, h, fill) {
  // This is a very simple and unsafe constructor. All we're doing is checking if the values exist.
  // "x || 0" just means "if there is a value for x, use that. Otherwise use 0."
  // But we aren't checking anything else! We could put "Lalala" for the value of x 
  this.x = x || 0;
  this.y = y || 0;
  this.w = w || 1;
  this.h = h || 1;
  this.fill = fill || '#AAAAAA';
}

// Draws this shape to a given context
Shape.prototype.draw = function(ctx) {
  ctx.fillStyle = this.fill;
  ctx.fillRect(this.x, this.y, this.w, this.h);
}

// Determine if a point is inside the shape's bounds
Shape.prototype.contains = function(mx, my) {
  // All we have to do is make sure the Mouse X,Y fall in the area between
  // the shape's X and (X + Height) and its Y and (Y + Height)
  return  (this.x <= mx) && (this.x + this.w >= mx) &&
          (this.y <= my) && (this.y + this.h >= my);
}

// check for resize. only valid if contains!
// 1 2 3
// 4   6
// 7 8 9
Shape.prototype.is_resize = function(mx, my, margin) {
  var r = 0;
  if (!this.contains(mx, my)) {
    console.error("is_resize called outside");
  } else if (mx-this.x <= margin) { // left
    if (my-this.y <= margin) {
      r = 1;
    } else if (my >= this.y+this.h-margin) {
      r = 7;
    } else {
      r = 4;
    }
  } else if (mx >= this.x+this.w-margin) { // right
    if (my-this.y <= margin) {
      r = 3;
    } else if (my >= this.y+this.h-margin) {
      r = 9;
    } else {
      r = 6;
    }
  } else if (my-this.y <= margin) {
    r = 2;
  } else if (my >= this.y+this.h-margin) {
    r = 8;
  }
  return r;
}

Shape.resize_cursor_styles = [
  'not-allowed',
  'nw-resize',
  'n-resize',
  'ne-resize',
  'w-resize',
  'not-allowed',
  'e-resize',
  'sw-resize',
  's-resize',
  'se-resize'
];

function CanvasState(canvas) {
  // **** First some setup! ****
  
  this.shape_changed_cb;
  this.new_shape_cb;
  this.bgImage = null;
  this.noImgPattern = null;
  this.canvas = canvas;
  this.width = canvas.width;
  this.height = canvas.height;
  this.ctx = canvas.getContext('2d');
  // This complicates things a little but but fixes mouse co-ordinate problems
  // when there's a border or padding. See getMouse for more detail
  var stylePaddingLeft, stylePaddingTop, styleBorderLeft, styleBorderTop;
  if (document.defaultView && document.defaultView.getComputedStyle) {
    this.stylePaddingLeft = parseInt(document.defaultView.getComputedStyle(canvas, null)['paddingLeft'], 10)      || 0;
    this.stylePaddingTop  = parseInt(document.defaultView.getComputedStyle(canvas, null)['paddingTop'], 10)       || 0;
    this.styleBorderLeft  = parseInt(document.defaultView.getComputedStyle(canvas, null)['borderLeftWidth'], 10)  || 0;
    this.styleBorderTop   = parseInt(document.defaultView.getComputedStyle(canvas, null)['borderTopWidth'], 10)   || 0;
  }
  // Some pages have fixed-position bars (like the stumbleupon bar) at the top or left of the page
  // They will mess up mouse coordinates and this fixes that
  var html = document.body.parentNode;
  this.htmlTop = html.offsetTop;
  this.htmlLeft = html.offsetLeft;

  // **** Keep track of state! ****
  
  this.dirty = true; // when set to false, the canvas will redraw everything
  this.shapes = [];  // the collection of things to be drawn
  this.dragging = false; // Keep track of when we are dragging
  this.resizing = 0; // Keep track of when we are resizing
  this.mousedown = false;
  // the current selected object. In the future we could turn this into an array for multiple selection
  this.selection = null;
  this.dragoffx = 0; // See mousedown and mousemove events for explanation
  this.dragoffy = 0;
  
  // **** Then events! ****
  
  // This is an example of a closure!
  // Right here "this" means the CanvasState. But we are making events on the Canvas itself,
  // and when the events are fired on the canvas the variable "this" is going to mean the canvas!
  // Since we still want to use this particular CanvasState in the events we have to save a reference to it.
  // This is our reference!
  var myState = this;
  
  //fixes a problem where double clicking causes text to get selected on the canvas
  canvas.addEventListener('selectstart', function(e) { e.preventDefault(); return false; }, false);
  // Up, down, and move are for dragging
  canvas.addEventListener('mousedown', function(e) {
    if (e.button != 0) {
      return;
    }
    var mouse = myState.getMouse(e);
    var mx = mouse.x;
    var my = mouse.y;
    var shape = myState.shape_at_cursor(mx, my);
    if (shape) {
      // Keep track of where in the object we clicked
      // so we can move it smoothly (see mousemove)
      myState.dragoffx = mx - shape.x;
      myState.dragoffy = my - shape.y;
      myState.selection = shape;
      myState.dirty = true;
      myState.resizing = shape.is_resize(mx, my, myState.selectionWidth)
      if (myState.resizing == 0) {
	myState.dragging = true;
      }
      return;
    }
    // havent returned means we have failed to select anything.
    // If there was an object selected, we deselect it
    if (myState.selection) {
      myState.selection = null;
      myState.dirty = true; // Need to clear the old selection border
    }
    myState.mousedown = true;
  }, true);
  canvas.addEventListener('mousemove', function(e) {
    var mouse = myState.getMouse(e);
    if (myState.dragging){
      // We don't want to drag the object by its top-left corner, we want to drag it
      // from where we clicked. Thats why we saved the offset and use it here
      myState.selection.x = mouse.x - myState.dragoffx;
      myState.selection.y = mouse.y - myState.dragoffy;   
      if (myState.selection.x < 0) {
	myState.selection.x = 0;
      } else if (myState.selection.x + myState.selection.w > this.width) {
	myState.selection.x = this.width - myState.selection.w;
      }
      if (myState.selection.y < 0) {
	myState.selection.y = 0;
      } else if (myState.selection.y + myState.selection.h > this.height) {
	myState.selection.y = this.height - myState.selection.h;
      }
      myState.dirty = true; // Something's dragging so we must redraw
      if (myState.shape_changed_cb) {
	myState.shape_changed_cb(myState.selection);
      }
    } else if (myState.resizing != 0) {
      var r = myState.resizing;
      var sel = myState.selection;
      var mx = mouse.x;
      var my = mouse.y;

      // special case, auto determine
      if (r == 5) {
	if (mx < sel.x) {
	  if (my < sel.y) {
	    myState.resizing = r = 1;
	  } else {
	    myState.resizing = r = 7;
	  }
	} else {
	  if (my < sel.y) {
	    myState.resizing = r = 3;
	  } else {
	    myState.resizing = r = 9;
	  }
	}
      }

      // west
      if (r == 1 || r == 4 || r == 7) {
	if (mx > sel.x+sel.w-MINSIZE) {
	  mx = sel.x+sel.w-MINSIZE;
	}
	sel.w += sel.x-mx; sel.x = mx;
      }

      // north
      if (r == 1 || r == 2 || r == 3) {
	if (my > sel.y+sel.h-MINSIZE) {
	  my = sel.y+sel.h-MINSIZE;
	}
	sel.h += sel.y-my; sel.y = my;
      }

      // east
      if (r == 3 || r == 6 || r == 9) {
	if (mx < sel.x+MINSIZE) {
	  mx = sel.x+MINSIZE;
	}
	sel.w += mx-(sel.x+sel.w);
      }

      // south
      if (r == 7 || r == 8 || r == 9) {
	if (my < sel.y+MINSIZE) {
	  my = sel.y+MINSIZE;
	}
	sel.h += my-(sel.y+sel.h);
      }

      if (myState.shape_changed_cb) {
	myState.shape_changed_cb(myState.selection);
      }

      myState.dirty = true;
    } else if (myState.mousedown) {
      if (myState.new_shape_cb) {
	var mouse = myState.getMouse(e);
	var shape = myState.new_shape_cb(mouse.x, mouse.y);
	myState.dragoffx = mx - shape.x;
	myState.dragoffy = my - shape.y;
	myState.selection = shape;
	myState.resizing = 5;
      }
    } else {
      var shape = myState.shape_at_cursor(mouse.x, mouse.y);
      if (shape) {
	var resize = shape.is_resize(mouse.x, mouse.y, myState.selectionWidth);
	if (resize != 0) {
	  canvas.style.cursor = Shape.resize_cursor_styles[resize];
	} else {
	  canvas.style.cursor = 'move';
	}
      } else {
	canvas.style.cursor = 'default';
      }
    }
  }, true);
  canvas.addEventListener('mouseup', function(e) {
    myState.dragging = false;
    myState.resizing = 0;
    myState.mousedown = false;
  }, true);
  /*
  // double click for making new shapes
  canvas.addEventListener('dblclick', function(e) {
    var mouse = myState.getMouse(e);
    myState.addShape(new Shape(mouse.x - 10, mouse.y - 10, MINSIZE, MINSIZE, 'rgba(0,255,0,.6)'));
  }, true);
  */
  
  // **** Options! ****
  
  this.selectionColor = '#CC0000';
  this.selectionWidth = 5;
  this.interval = 30;
  setInterval(function() { myState.draw(); }, myState.interval);
}

CanvasState.prototype.shape_at_cursor = function(mx, my) {
    var shapes = this.shapes;
    var l = shapes.length;
    for (var i = l-1; i >= 0; i--) {
      if (shapes[i].contains(mx, my)) {
        return shapes[i];
      }
    }
    return null;
}

CanvasState.prototype.addShape = function(shape) {
  this.shapes.push(shape);
  this.dirty = true;
  return this.shapes.length-1;
}

CanvasState.prototype.clear = function() {
  this.ctx.clearRect(0, 0, this.width, this.height);
}

// While draw is called as often as the INTERVAL variable demands,
// It only ever does something if the canvas gets invalidated by our code
CanvasState.prototype.draw = function() {
  // if our state is invalid, redraw and validate!
  if (this.dirty) {
    var ctx = this.ctx;
    var shapes = this.shapes;
    this.clear();

    if (this.bgImage) {
      this.ctx.drawImage(this.bgImage, 0, 0);
    } else {
      if (!this.noImgPattern) {
	var pattern = document.createElement("canvas");
	pattern.width = 100;
	pattern.height = 100;
	var pctx = pattern.getContext("2d");
	pctx.fillStyle = '#E8E8E8';
	pctx.fillRect(0, 0, pattern.width/2, pattern.height/2);
	pctx.fillRect(pattern.width/2, pattern.height/2, pattern.width, pattern.height);
	this.noImgPattern = ctx.createPattern(pattern, "repeat");
      }
      ctx.rect(0, 0, this.width, this.height);
      ctx.fillStyle = this.noImgPattern;
      ctx.fill();
    }
    
    // ** Add stuff you want drawn in the background all the time here **
    
    // draw all shapes
    var l = shapes.length;
    for (var i = 0; i < l; i++) {
      var shape = shapes[i];
      // We can skip the drawing of elements that have moved off the screen:
      if (shape.x > this.width || shape.y > this.height ||
          shape.x + shape.w < 0 || shape.y + shape.h < 0) continue;
      shapes[i].draw(ctx);
    }
    
    // draw selection
    // right now this is just a stroke along the edge of the selected Shape
    if (this.selection != null) {
      ctx.strokeStyle = this.selectionColor;
      ctx.lineWidth = this.selectionWidth;
      var mySel = this.selection;
      ctx.strokeRect(mySel.x,mySel.y,mySel.w,mySel.h);
    }
    
    // ** Add stuff you want drawn on top all the time here **
    
    this.dirty = false;
  }
}

CanvasState.prototype.get_shape_idx = function(shape) {
  if (!shape)
    return -1;
  return this.shapes.indexOf(shape);
}

CanvasState.prototype.get_selection_idx = function() {
  return this.get_shape_idx(this.selection);
}

CanvasState.prototype.get_selection = function() {
    if (!this.selection)
      return null;
    for (var i = 0; i < this.shapes.length; i++) {
      if (this.shapes[i] == this.selection)
	return this.selection;
    }
}

CanvasState.prototype.get_shape = function(idx) {
  return this.shapes[idx];
}

CanvasState.prototype.delete_shape_idx = function(idx) {
  if (this.shapes[idx] == this.selection) {
    this.selection = null;
  }
  this.shapes.splice(idx, 1);
  this.dirty = true;
}

CanvasState.prototype.delete_shapes = function() {
  var l = this.shapes.length;

  for (var i = l-1; i >= 0; i--) {
    this.shapes.splice(i, 1);
  }
  this.selection = null;
  this.dirty = true;
}

// Creates an object with x and y defined, set to the mouse position relative to the state's canvas
// If you wanna be super-correct this can be tricky, we have to worry about padding and borders
CanvasState.prototype.getMouse = function(e) {
  var element = this.canvas, offsetX = 0, offsetY = 0, mx, my;
  
  // Compute the total offset
  if (element.offsetParent !== undefined) {
    do {
      offsetX += element.offsetLeft;
      offsetY += element.offsetTop;
    } while ((element = element.offsetParent));
  }

  // Add padding and border style widths to offset
  // Also add the <html> offsets in case there's a position:fixed bar
  offsetX += this.stylePaddingLeft + this.styleBorderLeft + this.htmlLeft;
  offsetY += this.stylePaddingTop + this.styleBorderTop + this.htmlTop;

  mx = e.pageX - offsetX;
  my = e.pageY - offsetY;
  
  // We return a simple javascript object (a hash) with x and y defined
  return {x: mx, y: my};
}

CanvasState.prototype.redraw = function() {
  this.dirty = true;
}

CanvasState.prototype.set_bgImage = function(image) {
  this.bgImage = image;
  this.dirty = true;
}
