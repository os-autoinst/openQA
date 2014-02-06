var crpr;
// setup the callback function
function onEndCrop( coords, dimensions ) {
	$( "x1" ).value = coords.x1;
	$( "y1" ).value = coords.y1;
	$( "x2" ).value = coords.x2;
	$( "y2" ).value = coords.y2;
	$( "width" ).value = dimensions.width;
	$( "height" ).value = dimensions.height;
}

function onDraw( coords, dimensions ) {
	$( "x1" ).value = coords.x1;
	$( "y1" ).value = coords.y1;
	$( "x2" ).value = coords.x2;
	$( "y2" ).value = coords.y2;
	$( "width" ).value = dimensions.width;
	$( "height" ).value = dimensions.height;
}

function getEventTarget(evt) {
	var targ = (evt.target) ? evt.target : evt.srcElement;
	if(targ != null) {
		if(targ.nodeType == 3)
		  targ = targ.parentNode;
	}
	return targ;
}

function isvalnum(input) {
	return (input - 0) == input && input.length > 0 && input > 0;
}

function findPosition(oElement) {
	if(typeof( oElement.offsetParent ) != "undefined") {
		for(var posX = 0, posY = 0; oElement; oElement = oElement.offsetParent) {
			posX += oElement.offsetLeft;
			posY += oElement.offsetTop;
		}
		return [ posX, posY ];
	}
	else {
		return [ oElement.x, oElement.y ];
	}
}

function getCoordinates(e) {
	var PosX = 0;
	var PosY = 0;
	var ImgPos;
	ImgPos = findPosition($("testImage"));
	if (!e) var e = window.event;
	if (e.pageX || e.pageY) {
		PosX = e.pageX;
		PosY = e.pageY;
	}
	else if (e.clientX || e.clientY) {
		PosX = e.clientX + document.body.scrollLeft + document.documentElement.scrollLeft;
		PosY = e.clientY + document.body.scrollTop + document.documentElement.scrollTop;
	}
	PosX = PosX - ImgPos[0];
	PosY = PosY - ImgPos[1];
	$("xc").value = PosX;
	$("yc").value = PosY;
	$("click-location-pointer").style.left = PosX + "px";
	$("click-location-pointer").style.top = PosY + "px";
}

function cropreinit() { 
	crpr = new Cropper.Img("testImage", {
		onEndCrop: onEndCrop,
		onDraw: onDraw,
		displayOnInit: true,
		onloadCoords: { x1: $("x1").value, y1: $("y1").value, x2: $("x2").value, y2: $("y2").value }
	}); 
}

function cropinit() { 
	if(initcoords) {
		crpr = new Cropper.Img("testImage", {
			onEndCrop: onEndCrop,
			onDraw: onDraw,
			displayOnInit: true,
			onloadCoords: initcoords
		});
	}
	else {
		crpr = new Cropper.Img("testImage", {
			onEndCrop: onEndCrop,
			onDraw: onDraw 
		});
	}
}

function clickinit() {
	if(initclick) {
		$("xc").value = initclick.PosX;
		$("yc").value = initclick.PosY;
		$("click-location-pointer").style.left = initclick.PosX + "px";
		$("click-location-pointer").style.top = initclick.PosY + "px";
	}
	return true;
}
