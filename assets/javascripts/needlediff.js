function NeedleDiff(id, width, height) {
  if (!(this instanceof NeedleDiff)) {
    return new NeedleDiff(id, width, height);
  }

  var canvas = $('<canvas/>');
  var container = $("#" + id);
  var divide = 0.5;

  canvas.css('position", "absolute');
  this.ctx = canvas[0].getContext('2d');
  this.screenshotImg = null;
  this.needleImg = null;
  this.areas = [];
  this.matches = [];
  this.showSimilarity = [];

  // Event handlers
  canvas.on('mousemove', handler);
  canvas.on('mousedown', handler);
  canvas.on('mouseup', handler);

  var self = this;

  function handler(ev) {
    if (ev.offsetX == undefined) {
      ev._x = ev.pageX - canvas.offset().left;
      ev._y = ev.pageY - canvas.offset().top;
    } else {
      ev._x = ev.offsetX;
      ev._y = ev.offsetY;
    }

    var eventHandler = self[ev.type];
    if (typeof eventHandler == 'function') {
      eventHandler.call(self, ev);
    }
  }

  // Draw canvas into its container
  canvas.attr('width', width);
  canvas.attr('height', height);
  container.css('border: 1px solid black; margin: 0px; position: relative; width: '+width+'px; height: '+height+'px;');
  container.append(canvas);

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

    // create gray version of it in off screen canvas
    var gray_canvas = document.createElement('canvas');
    gray_canvas.width = image.width;
    gray_canvas.height = image.height;
    
    var gray_context = gray_canvas.getContext('2d');
    
    gray_context.drawImage(image, 0, 0);
    var imageData = gray_context.getImageData(0, 0, image.width, image.height);
    var data = imageData.data;

    for(var i = 0; i < data.length; i += 4) {
      var brightness = 0.34 * data[i] + 0.5 * data[i + 1] + 0.16 * data[i + 2];
      brightness *= 0.6;
      // red
      data[i] = brightness;
      // green
      data[i + 1] = brightness;
      // blue
      data[i + 2] = brightness;
    }

    // overwrite original image
    gray_context.putImageData(imageData, 0, 0);
    this.gray_canvas = gray_canvas;

    this.draw();
  }.bind(this));
}

NeedleDiff.prototype.setNeedle = function(src, areas, matches) {
  this.areas = areas;
  this.matches = matches;
  this.showSimilarity = new Array(matches.length);
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
  // First of all, draw the screenshot as gray background (if ready)
  if (!this.screenshotImg) {
    return;
  }

  if (this.matches.length) {
    this.ctx.drawImage(this.gray_canvas, 0, 0);
  } else {
    this.ctx.drawImage(this.screenshotImg, 0, 0);
  }

  // Then, check if there is a needle to compare with
  if (!this.needleImg) {
    return;
  }

  // Calculate the pixel in which the division will be done
  var split = this.divide * this.width;
  if (split < 1) {
    split = 1;
  }

  // Draw all matches
  this.matches.forEach(function(a, idx) {

    // If some part of the match is at the left of the handle...
    var width = a['width'];
    var x = a['xpos'];

    var orig;
    var lineWidth = 1;

    if (split > x) {

      // ...fill that left part with the original needle's area

      if (split - x < width) {
        width = split - x;
      } else {
        width += 1;
      }

      this.ctx.strokeStyle = "rgb(64,224,208)";

      orig = this.areas[idx];
      this.ctx.drawImage(this.needleImg, orig['xpos'], orig['ypos'],
                         width, a['height'], x, a['ypos'], width, a['height']);

      this.ctx.lineWidth = lineWidth;
      this.ctx.beginPath();
      this.ctx.moveTo(x + width, a['ypos'] - lineWidth);
      this.ctx.lineTo(x, a['ypos'] - lineWidth);
      this.ctx.lineTo(x, a['ypos'] + a['height'] + lineWidth);
      this.ctx.lineTo(x + width, a['ypos'] + a['height'] + lineWidth);
      this.ctx.lineTo(x + width, a['ypos'] - lineWidth);
      this.ctx.stroke();
    }

    width = a['width'];

    if (split < x + width) {

      // ...fill the right part with the new screenshot (not gray)

      this.ctx.strokeStyle = NeedleDiff.shapecolor(a['type']);

      var start = split;
      if (split < a['xpos'])
        start = a['xpos'];

      orig = this.areas[idx];
      var rwidth = a['xpos'] + a['width'] - start;
      this.ctx.drawImage(this.screenshotImg, start, a['ypos'],
                         rwidth,
                         a['height'], start, a['ypos'], rwidth, a['height']);

      this.ctx.lineWidth = lineWidth;
      this.ctx.beginPath();
      this.ctx.moveTo(start, a['ypos'] - lineWidth);
      this.ctx.lineTo(a['xpos'] + a['width'] + lineWidth, a['ypos'] - lineWidth);
      this.ctx.lineTo(a['xpos'] + a['width'] + lineWidth, a['ypos'] + a['height'] + lineWidth);
      this.ctx.lineTo(start, a['ypos'] + a['height'] + lineWidth);
      this.ctx.lineTo(start, a['ypos'] - lineWidth);
      this.ctx.stroke();
    }

    // And the similarity, if needed
    if (split > a['xpos'] && split < a['xpos'] + a['width']) {
      this.ctx.strokeStyle = "rgb(0, 0, 0)";
      this.ctx.lineWidth = 3;
      this.ctx.font = "bold 14px Arial";
      var text = a['similarity']+"%";
      var textSize = this.ctx.measureText(text);
      var tx;
      var ty = a['ypos'] + a['height'] + 19;
      if (ty > this.screenshotImg.height) {
        ty = a['ypos'] - 4;
      }
      if (split + textSize.width < a['xpos'] + a['width']) {
        tx = a['xpos'] + a['width'] - textSize.width - 1;
        this.ctx.strokeText(text, tx, ty);
        this.ctx.fillStyle = NeedleDiff.shapecolor(a['type']);
        this.ctx.fillText(text, tx, ty);
      }

      text = "Needle";
      textSize = this.ctx.measureText(text);
      if (a['xpos'] + textSize.width < split) {
        tx = a['xpos'] + 1;
        this.ctx.strokeText(text, tx, ty);
        this.ctx.fillStyle = "rgb(64,224,208)";
        this.ctx.fillText(text, tx, ty);
      }

    }

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
  var redraw = false;

  // Show match percentage if the cursor is over the match
  this.matches.forEach(function(a, idx) {
    if (event._x > a['xpos'] && event._x < a['xpos'] + a['width'] &&
        event._y > a['ypos'] && event._y < a['ypos'] + a['height']) {
      if (!this.showSimilarity[idx]) redraw = true;
      this.showSimilarity[idx] = true;
    } else {
      if (this.showSimilarity[idx]) redraw = true;
      this.showSimilarity[idx] = false;
    }
  }.bind(this));

  // Drag
  if (this.dragstart === true) {
    this.divide = divide;
  } else if (redraw) {
    // FIXME: Really ugly
    this.draw();
  }

  // Change cursor
  if (Math.abs(this.divide - divide) < 0.01) {
    this.container.css("cursor", "col-resize");
  } else {
    this.container.css("cursor", "auto");
  }
};

NeedleDiff.prototype.mouseup = function(event) {
  this.dragstart = false;
}

NeedleDiff.shapecolors = {
  'ok':      'rgba(  0, 255, 0, .9)',
  'fail':    'rgba(255,   0, 0, .9)'
};

NeedleDiff.shapecolor = function(type) {
  if (type in NeedleDiff.shapecolors) {
    return NeedleDiff.shapecolors[type];
  }
  return "pink";
};
