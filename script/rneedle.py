#!/usr/bin/env python

# Copyright (c) 2016 SUSE LLC
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along
# with this program; if not, see <http://www.gnu.org/licenses/>.

"""A quick local viewer of needles' png/json pair.

In openSUSE, the runtime requires "python-opencv" and "libopencv2_4" packages.

[Usage]

    In a needles directory contains foo.png and foo.json, e.g.:

    $ python rneedles.py foo

    On a local window, it draws "green", "red" and "orange"
    rectangles on foo.png, as to the "match", "exclude" and "ocr"
    types of area defined in the foo.json.

"""

import json
import cv2
import argparse

parser = argparse.ArgumentParser()
parser.add_argument("fn")
args = parser.parse_args()
fn = args.fn

with open( fn + '.json' ) as data_file:
    data = json.load(data_file)

img = cv2.imread(fn + '.png', 3)

# Colors defined in opencv BGR convention. The variable name is
# coupled with the areas 'type' defined in needle: "match",
# "exclude" and "ocr".
COLOR_MATCH = (0, 255, 0)   # green
COLOR_EXCLUDE = (0, 0, 255) # red
COLOR_OCR = (0, 255, 255)   # yellow

for d in data['area']:
    x1 = d['xpos']
    y1 = d['ypos']
    x2 = d['xpos'] + d['width']
    y2 = d['ypos'] + d['height']
    color = '_'.join(['COLOR', d['type'].upper()])
    cv2.rectangle(img,(x1,y1),(x2,y2), globals()[color], 2)

cv2.imshow(fn, img)
cv2.waitKey(0)
cv2.destroyAllWindows()
