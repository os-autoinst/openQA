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
    this.draw();
  }.bind(this));
}

NeedleDiff.prototype.setNeedle = function(src, areas, matches) {
  this.areas = areas;
  this.matches = matches;
  if (src) {
    var image = new Image();
    image.src = src;
    image.addEventListener('load', function(ev) {
      this.needleImg = image;
      this.draw();
    }.bind(this));
  } else {
    this.needleImg = null;
    this.draw();
  }
}

NeedleDiff.prototype.draw = function() {
  // First of all, draw the screenshot as background (if ready)
  if (!this.screenshotImg) {
    return;
  }
  this.ctx.drawImage(this.screenshotImg, 0, 0);

  // Then, check if there is a needle to compare with
  if (!this.needleImg) {
    return;
  }
  
  // Calculate the pixel in which the division will be done
  var split = this.divide * this.width;
  if (split < 1) {
    split = 1;
  }
  
  // Draw the needle
  this.ctx.drawImage(this.needleImg, 0, 0, split, this.height, 0, 0, split, this.height);
  // Draw all areas
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
  // Draw all matches, no matter where they are
  this.matches.forEach(function(a) {
    this.ctx.strokeStyle = NeedleDiff.shapecolor(a['type']);
    this.ctx.lineWidth = 3;
    this.ctx.strokeRect(a['xpos'], a['ypos'], a['width'], a['height']);
  }.bind(this));
  // Draw the handle
  this.ctx.fillStyle = "rgb(255, 145, 75)";
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
  'ok':      'rgba(  0, 255, 0, .8)',
  'fail':    'rgba(255,   0, 0, .8)',
};

NeedleDiff.shapecolor = function(type) {
  if (type in NeedleDiff.shapecolors) {
    return NeedleDiff.shapecolors[type];
  }
  return "pink";
}
