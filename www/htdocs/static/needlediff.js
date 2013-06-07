function NeedleDiff(id, width, height) {
  if (!(this instanceof NeedleDiff)) {
    return new NeedleDiff(id, width, height);
  }

  var canvas = document.createElement('canvas');
  var container = document.getElementById(id);
  var divide = 0.5;
  
  canvas.writeAttribute('style','position: absolute;');
  this.ctx = canvas.getContext('2d');
  this.screenshotImg = null;
  this.needleImg = null;
  this.areas = [];
  this.matches = [];
  
  // Event handlers
  canvas.addEventListener('mousemove', handler, false);
  canvas.addEventListener('mousedown', handler, false);
  canvas.addEventListener('mouseup', handler, false);

  var self = this;

  function handler(ev) {
    ev._x = ev.layerX;
    ev._y = ev.layerY;

    var eventHandler = self[ev.type];
    if (typeof eventHandler == 'function') {
      eventHandler.call(self, ev);
    }
  }

  // Draw canvas into its container
  canvas.setAttribute('width', width);
  canvas.setAttribute('height', height);
  container.writeAttribute('style','border: 1px solid black; margin: 0px; position: relative; width: '+width+'px; height: '+height+'px;');
  container.appendChild(canvas);

  Object.defineProperty(this, 'container', {
    get: function() {
      return container;
    }
  });

  Object.defineProperty(this, 'ready', {
    get: function() {
      return (this.screenshotImg && this.needleImg);
    }
  });

  Object.defineProperty(this, 'width', {
    get: function() {
      return width;
    }
  });

  Object.defineProperty(this, 'height', {
    get: function() {
      return height;
    }
  });

  Object.defineProperty(this, 'divide', {
    get: function() {
      return divide;
    },
    set: function(value) {
      if (value > 1) {
        value = (value / 100);
      }

      divide = value;
      this.draw();
    }
  });
}

NeedleDiff.prototype.setScreenshot = function(screenshotSrc) {
  var image = new Image();
  image.src = screenshotSrc;
  image.addEventListener('load', function(ev) {
    this.screenshotImg = image;
    if (this.ready) {
      this.draw();
    }
  }.bind(this));
}

NeedleDiff.prototype.setNeedle = function(src, areas, matches) {
  this.areas = areas;
  this.matches = matches;
  var image = new Image();
  image.src = src;
  image.addEventListener('load', function(ev) {
    this.needleImg = image;
    if (this.ready) {
      this.draw();
    }
  }.bind(this));
}

NeedleDiff.prototype.draw = function() {
  if (!this.ready) {
    return;
  }
  
  var split = this.divide * this.width;
  if (split < 1) {
    split = 1;
  }
  
  this.ctx.drawImage(this.screenshotImg, 0, 0);
  this.ctx.drawImage(this.needleImg, 0, 0, split, this.height, 0, 0, split, this.height);
  // Currently we always draw all areas and matches
  this.areas.forEach(function(a) {
    this.ctx.fillStyle = NeedleDiff.shapecolor(a['type']);
    // Only areas in the left of the handle are drew
    var x = a['xpos'];
    if (x < split) {
      // And only the part at the left of the handle
      var width = a['width'];
      if (split - x < width) {
        width = split - x;
      }
      this.ctx.fillRect(x, a['ypos'], width, a['height']);
    }
  }.bind(this));
  this.matches.forEach(function(a) {
    this.ctx.strokeStyle = NeedleDiff.shapecolor(a['type']);
    this.ctx.strokeRect(a['xpos'], a['ypos'], a['width'], a['height']);
  }.bind(this));
  // Draw the handle
  this.ctx.fillStyle = "rgb(220, 50, 50)";
  this.ctx.fillRect(split - 1, 0, 2, this.height);
}

NeedleDiff.prototype.mousedown = function(event) {
  var divide = event._x / this.width;
  // To prevent the cursor change in chrome/chromium
  event.preventDefault();
  if (Math.abs(this.divide - divide) < 0.01) {
    this.dragstart = true;
  }
};

NeedleDiff.prototype.mousemove = function(event) {
  var divide = event._x / this.width;
  // Drag
  if (this.dragstart === true) {
    this.divide = divide;
  }
  // Change cursor
  if (Math.abs(this.divide - divide) < 0.01) {
    this.container.style.cursor = 'col-resize';
  } else {
    this.container.style.cursor = 'auto';
  }
};

NeedleDiff.prototype.mouseup = function(event) {
  this.dragstart = false;
}

NeedleDiff.shapecolors = {
  'match':   'rgba(  0, 255, 0, .5)',
  'exclude': 'rgba(255,   0, 0, .5)',
  'ocr':     'rgba(255, 255, 0, .5)',
  'ok':      'rgba(  0, 255, 0, .5)',
  'fail':    'rgba(255,   0, 0, .5)',
};

NeedleDiff.shapecolor = function(type) {
  if (type in NeedleDiff.shapecolors) {
    return NeedleDiff.shapecolors[type];
  }
  return "pink";
}
