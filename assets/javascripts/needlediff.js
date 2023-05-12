function NeedleDiff(id, width, height) {
  if (!(this instanceof NeedleDiff)) {
    return new NeedleDiff(id, width, height);
  }

  var canvas = $('<canvas/>');
  var container = $('#' + id);
  var divide = 0.5;

  canvas.css('position", "absolute');
  this.ctx = canvas[0].getContext('2d');
  this.screenshotImg = null;
  this.needleImg = null;
  this.areas = [];
  this.matches = [];

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
  container.css(
    'border: 1px solid black; margin: 0px; position: relative; width: ' + width + 'px; height: ' + height + 'px;'
  );
  container.append(canvas);

  Object.defineProperty(this, 'container', {
    get: function () {
      return container;
    }
  });

  Object.defineProperty(this, 'width', {
    get: function () {
      return width;
    }
  });

  Object.defineProperty(this, 'height', {
    get: function () {
      return height;
    }
  });

  Object.defineProperty(this, 'divide', {
    get: function () {
      return divide;
    },
    set: function (value) {
      if (value > 1) {
        value = value / 100;
      }

      divide = value;
      this.draw();
    }
  });
}

/**
 * Function ensuring that the text fits into the area rectangle.
 * @param {Object} ctx - The Canvas context.
 * @param {Object} area - The OCR area to be drawn into.
 * @param {Object} txtStyle - The target text style for calibration.
 * @returns {number} The calculated font size.
 */
function calcFontSize(ctx, area, txtStyle) {
  const ocrLines = area.ocr_str.split('\n');

  // 1px margin in height
  let ret = Math.ceil(((area.height - ocrLines.length - 1) / ocrLines.length) - 1);

  ctx.font = txtStyle.weight + ' ' + ret + 'px ' + txtStyle.typeface;
  for (line of ocrLines) {
    let ocrLinesWidth = ctx.measureText(line).width;
    while (ocrLinesWidth > area.width - 2) {
      ret--;
      ctx.font = txtStyle.weight + ' ' + ret + 'px ' + txtStyle.typeface;
      ocrLinesWidth = ctx.measureText(line).width;
    }
  }
  return ret;
}

/**
 * Method drawing the OCR text into the OCR area.
 * @param {Object} needlediff - The needlediff containing the canvas context.
 * @param {Object} area - The OCR area to be drawn into.
 */
function drawOcrTxt(needlediff, area) {
  const txtStyle = {
    alignment: 'center',
    typeface: 'Arial',
    color: 'rgb(64,224,208)',
    weight: 'bold'
  }
  const fontSize = calcFontSize(needlediff.ctx, area, txtStyle);
  const ocrLines = area.ocr_str.split('\n');
  const ocrTxtXPos = Math.ceil(area.xpos + area.width / 2);

  // Body line appears to be at about 1/3 of whole font height
  let ocrTxtYPos = Math.floor(area.ypos + area.height / 2 + fontSize / 3 -
                   ((ocrLines.length - 1) * fontSize) / 2);

  needlediff.ctx.textAlign = txtStyle.alignment;
  needlediff.ctx.fillStyle = txtStyle.color;
  needlediff.ctx.font = txtStyle.weight + ' ' + fontSize + 'px ' +
                        txtStyle.typeface;

  for (line of ocrLines) {
    needlediff.ctx.fillText(line, ocrTxtXPos, ocrTxtYPos);

    // 1px space between lines
    ocrTxtYPos += fontSize + 1;
  }
}

NeedleDiff.prototype.draw = function () {
  // First of all, draw the screenshot as gray background (if ready)
  if (!this.screenshotImg) {
    return;
  }

  if (this.matches.length) {
    this.ctx.drawImage(this.gray_canvas, 0, 0);
  } else {
    this.ctx.drawImage(this.screenshotImg, 0, 0);
  }

  // Calculate the pixel in which the division will be done
  var split = this.divide * this.width;
  if (split < 1) {
    split = 1;
  }

  // Show full diff
  if (this.fullNeedleImg) {
    this.ctx.drawImage(this.fullNeedleImg, 0, 0, split, this.height, 0, 0, split, this.height);
  }

  // Draw all match boxes
  this.matches.forEach(
    function (a, idx) {
      // If some part of the match is at the left of the handle...
      var width = a['width'];
      var x = a['xpos'];

      var orig;
      var lineWidth = 1;

      var y_start = a['ypos'] - lineWidth;
      var y_end = a['ypos'] + a['height'] + lineWidth;
      if (y_start < 0) {
        y_start = 0;
      }
      if (y_end > this.height) {
        y_end = this.height;
      }

      // draw match/area frames
      orig = this.areas[idx];
      this.ctx.lineWidth = lineWidth;
      if (split > x && !this.fullNeedleImg) {
        // fill left part with original needle's area
        var usedWith = width;
        if (split - x < usedWith) {
          usedWith = split - x;
        } else {
          usedWith += 1;
        }
        if (!this.fullNeedleImg) {
          // draw matching part of needle image
          this.ctx.strokeStyle = NeedleDiff.strokecolor(a.type);
          if (this.needleImg) {
            this.ctx.drawImage(this.needleImg, orig.xpos, orig.ypos, usedWith, a.height, x, a.ypos, usedWith, a.height);
          } else if (a.ocr_str) {
            drawOcrTxt(this, a);
          } else return;

          // draw frame of match area
          this.ctx.lineWidth = lineWidth;
          this.ctx.beginPath();
          this.ctx.moveTo(x + usedWith, y_start);
          this.ctx.lineTo(x, y_start);
          this.ctx.lineTo(x, y_end);
          this.ctx.lineTo(x + usedWith, y_end);
          this.ctx.lineTo(x + usedWith, y_start);
          this.ctx.stroke();
        }
      }

      if (split > orig.xpos && this.fullNeedleImg) {
        // draw frame of original area
        this.ctx.strokeStyle = NeedleDiff.strokecolor('originalArea');
        this.ctx.beginPath();
        var origX = orig.xpos;
        var origY = orig.ypos - lineWidth;
        var origYEnd = orig.ypos + orig.height + lineWidth;
        var origWidth = split - origX < a.width ? split - origX : a.width + 1;
        this.ctx.moveTo(origX + origWidth, origY);
        this.ctx.lineTo(origX, origY);
        this.ctx.lineTo(origX, origYEnd);
        this.ctx.lineTo(origX + origWidth, origYEnd);
        this.ctx.lineTo(origX + origWidth, origY);
        this.ctx.stroke();
      }

      if (split < x + width) {
        // fill the right part with the new screenshot (not gray)
        this.ctx.strokeStyle = NeedleDiff.shapecolor(a.type);

        var start = split;
        if (split < a['xpos']) start = a['xpos'];

        orig = this.areas[idx];
        var rwidth = a['xpos'] + a['width'] - start;
        this.ctx.drawImage(
          this.screenshotImg,
          start,
          a['ypos'],
          rwidth,
          a['height'],
          start,
          a['ypos'],
          rwidth,
          a['height']
        );

        this.ctx.lineWidth = lineWidth;
        this.ctx.beginPath();
        this.ctx.moveTo(start, y_start);
        this.ctx.lineTo(a['xpos'] + a['width'] + lineWidth, y_start);
        this.ctx.lineTo(a['xpos'] + a['width'] + lineWidth, y_end);
        this.ctx.lineTo(start, y_end);
        this.ctx.lineTo(start, y_start);
        this.ctx.stroke();
      }
    }.bind(this)
  );

  // Draw all exclude boxes
  this.areas.forEach(
    function (a, idx) {
      if (a.type !== 'exclude') {
        return;
      }
      this.ctx.fillStyle = NeedleDiff.shapecolor(a.type);
      this.ctx.strokeStyle = NeedleDiff.strokecolor(a.type);
      this.ctx.fillRect(a.xpos, a.ypos, a.width, a.height);
      this.ctx.strokeRect(a.xpos, a.ypos, a.width, a.height);
    }.bind(this)
  );

  // Draw all match labels
  this.matches.forEach(
    function (a, idx) {
      // And the similarity, if needed
      if (split > a['xpos'] && split < a['xpos'] + a['width']) {
        this.ctx.strokeStyle = 'rgb(0, 0, 0)';
        this.ctx.lineWidth = 3;
        this.ctx.font = 'bold 14px Arial';
        this.ctx.textAlign = 'left';
        var text = a['similarity'] + '%';
        var textSize = this.ctx.measureText(text);
        var tx;
        var ty = a['ypos'] + a['height'] + 19;
        if (ty > this.height) {
          // Place text above match box
          ty = a['ypos'] - 10;
        }
        if (ty < 14) {
          // Place text in match box (text is 14px large)
          ty = a['ypos'] + a['height'] - 10;
        }
        if (split + textSize.width < a['xpos'] + a['width']) {
          tx = a['xpos'] + a['width'] - textSize.width - 1;
          this.ctx.strokeText(text, tx, ty);
          this.ctx.fillStyle = NeedleDiff.shapecolor(a['type']);
          this.ctx.fillText(text, tx, ty);
        }

        if (!this.fullNeedleImg) {
          text = 'Needle';
          textSize = this.ctx.measureText(text);
          if (a['xpos'] + textSize.width < split) {
            tx = a['xpos'] + 1;
            this.ctx.strokeText(text, tx, ty);
            this.ctx.fillStyle = 'rgb(64,224,208)';
            this.ctx.fillText(text, tx, ty);
          }
        }
      }
    }.bind(this)
  );
  // Draw the handle
  this.ctx.fillStyle = 'rgb(255, 145, 75)';
  this.ctx.fillRect(split - 1, 0, 2, this.height);
};

NeedleDiff.prototype.mousedown = function (event) {
  event._x *= this.width / event.currentTarget.clientWidth;
  event._y *= this.height / event.currentTarget.clientHeight;
  var divide = event._x / this.width;
  // To prevent the cursor change in chrome/chromium
  event.preventDefault();
  if (Math.abs(this.divide - divide) < 0.01) {
    this.dragstart = true;
  }
};

NeedleDiff.prototype.mousemove = function (event) {
  event._x *= this.width / event.currentTarget.clientWidth;
  event._y *= this.height / event.currentTarget.clientHeight;
  var divide = event._x / this.width;
  var redraw = false;

  // Drag
  if (this.dragstart === true) {
    this.divide = divide;
  } else if (redraw) {
    // FIXME: Really ugly
    this.draw();
  }

  // Change cursor
  if (Math.abs(this.divide - divide) < 0.01) {
    this.container.css('cursor', 'col-resize');
  } else {
    this.container.css('cursor', 'auto');
  }
};

NeedleDiff.prototype.mouseup = function (event) {
  this.dragstart = false;
};

NeedleDiff.strokecolors = {
  ok: 'rgb( 64, 224, 208)',
  fail: 'rgb( 64, 224, 208)',
  exclude: 'rgb(100, 100, 100)',
  originalArea: 'rgb(200, 200, 200)'
};

NeedleDiff.strokecolor = function (type) {
  if (type in NeedleDiff.strokecolors) {
    return NeedleDiff.strokecolors[type];
  }
  return 'pink';
};

NeedleDiff.shapecolors = {
  ok: 'rgba(  0, 255,   0, .9)',
  fail: 'rgba(255,   0,   0, .9)',
  exclude: 'rgba(225, 215, 215, .7)'
};

NeedleDiff.shapecolor = function (type) {
  if (type in NeedleDiff.shapecolors) {
    return NeedleDiff.shapecolors[type];
  }
  return 'pink';
};

function setDiffScreenshot(screenshotSrc) {
  $('<img src="' + screenshotSrc + '">').on('load', function () {
    var image = $(this).get(0);

    // create gray version of it in off screen canvas
    var gray_canvas = document.createElement('canvas');
    gray_canvas.width = image.width;
    gray_canvas.height = image.height;

    // set screenshot resolution
    window.differ = new NeedleDiff('needle_diff', image.width, image.height);
    window.differ.screenshotImg = image;
    window.differ.gray_canvas = gray_canvas;
    setNeedle();

    var gray_context = gray_canvas.getContext('2d');

    gray_context.drawImage(image, 0, 0);
    var imageData = gray_context.getImageData(0, 0, image.width, image.height);
    var data = imageData.data;

    for (var i = 0; i < data.length; i += 4) {
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
    window.differ.gray_canvas = gray_canvas;

    window.differ.draw();
  });
}

function setNeedle(sel, kind) {
  // default to the same mode which was used previously
  if (!kind) {
    kind = window.differ.fullNeedleImg ? 'full-diff' : 'area-only-diff';
  }
  // set parameter according to the selected kind of diff
  var assignFullNeedleImg;
  if (kind === 'area-only-diff') {
    assignFullNeedleImg = false;
  } else if (kind === 'full-diff') {
    assignFullNeedleImg = true;
  } else {
    window.alert(kind + ' is not available (yet)!');
    return;
  }

  var currentSelection = $('#needlediff_selector tbody tr.selected');
  if (sel) {
    // set needle for newly selected item
    currentSelection.removeClass('selected');
    sel.addClass('selected');
    // update label/button text
    var label = sel.data('label');
    if (!label) {
      label = 'Screenshot';
    }
    $('#current_needle_label').text(label);
  } else {
    // set needle for current selection
    sel = currentSelection;
  }

  // set areas/matches
  if (sel.length) {
    // show actual candidate
    window.differ.areas = sel.data('areas');
    window.differ.matches = sel.data('matches');
    $('#screenshot_button').prop('disabled', false);
  } else {
    // show only a screenshot
    window.differ.areas = window.differ.matches = [];
    $('#screenshot_button').prop('disabled', true);
  }

  // set image
  var src = sel.data('image');
  if (src) {
    $('<img src="' + src + '">').on('load', function () {
      var image = $(this).get(0);
      window.differ.needleImg = image;
      window.differ.fullNeedleImg = assignFullNeedleImg ? image : null;
      window.differ.draw();
    });
  } else {
    window.differ.needleImg = null;
    window.differ.fullNeedleImg = null;
    window.differ.draw();
  }

  // close menu again, except user is selecting text to copy
  var needleDiffSelector = document.getElementById('needlediff_selector');
  var selection = window.getSelection();
  var userSelectedText = !selection.isCollapsed && $.contains(needleDiffSelector, selection.anchorNode);
  if (!userSelectedText && $(needleDiffSelector).is(':visible')) {
    $('#candidatesMenu').dropdown('toggle');
  }
}
