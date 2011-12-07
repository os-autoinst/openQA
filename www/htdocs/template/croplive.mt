? extends 'defstyle-18'

? block additional_headlines => sub {
<script src="/static/prototype.js" type="text/javascript"></script>
<script src="/static/scriptaculous/scriptaculous.js" type="text/javascript"></script>
<script src="/static/cropper.uncompressed.js" type="text/javascript"></script>
<script src="/static/crop.js" type="text/javascript"></script>
<script type="text/javascript">
<!--
var initcoords = <?= (%$processed)?encoded_string("{ x1: $processed->{'x1'}, y1: $processed->{'y1'}, x2: $processed->{'x2'}, y2: $processed->{'y2'} }"):'0' ?>;
var initclick = <?= (%$processed)?encoded_string("{ PosX: $processed->{'xc'}, PosY: $processed->{'yc'} }"):'0' ?>;

Event.observe(window, "load", function() { 
	modechange(); // set mode to crop
	cropinit();
	clickinit();
});

document.onclick = function(e) {
	if(!e) e=window.event;
	elem = getEventTarget(e);
	if(elem.nodeName == "BODY" || elem.nodeName == "HTML") {
		if ($("cropp").checked) {
			crpr.options.onloadCoords=null;
			crpr.reset();
		}
	}
}

function checkform(f) {
	if(
	  ! isvalnum(f.x2.value) ||
	  ! isvalnum(f.y2.value) ||
	  ! isvalnum(f.width.value) ||
	  ! isvalnum(f.height.value) ||
	  ! isvalnum(f.xc.value) ||
	  ! isvalnum(f.yc.value) ) {
		alert("Make your selection first!");
		return false;
	}
	return true;
}

function resetform() {
	$("testImage").onmousedown = 0;
	$("click-location-pointer").onmousedown = 0;
	$("click-location-pointer").style.display = "none";
	$("testImage").style.cursor = "";
	crpr.options.onloadCoords=null;
	crpr.reset();
	$("xc").defaultValue = 0;
	$("yc").defaultValue = 0;
	$("cropp").checked = 1;
	$("cpi1").setOpacity(1);
	$("cpi2").setOpacity(1);
	$("cpi3").setOpacity(1);
	$("cli1").setOpacity(0.3);
	$("click-location-pointer").style.left = "0px";
	$("click-location-pointer").style.top = "0px";
}

function modechange() {
	if ($("cropp").checked) {
		$("cpi1").setOpacity(1);
		$("cpi2").setOpacity(1);
		$("cpi3").setOpacity(1);
		$("cli1").setOpacity(0.3);
		$("testImage").onmousedown = 0;
		$("click-location-pointer").onmousedown = 0;
		$("click-location-pointer").style.display = "none";
		$("testImage").style.cursor = "";
		if(crpr) {
			cropreinit();
			if($("width").value == 0) {
				crpr.options.onloadCoords=null;
				crpr.reset();
			}
		}
	}
	else {
		$("cpi1").setOpacity(0.3);
		$("cpi2").setOpacity(0.3);
		$("cpi3").setOpacity(0.3);
		$("cli1").setOpacity(1);
		crpr.remove();
		$("testImage").onmousedown = getCoordinates;
		$("click-location-pointer").style.display = "block";
		$("click-location-pointer").onmousedown = getCoordinates;
		$("testImage").style.cursor = "crosshair";
	}
}
-->
</script>
? }

? block locbar => sub {
?= super()
&gt; Live Crop
&gt; <a href="/running/<?= $testname ?>"><?= $testname ?></a>
&gt; <?= $testmodule ?>
? }

? block content => sub {
<div class="grid_5 alpha" id="left_col">
	<div class="grid_5 box box-shadow alpha" id="actions_box">
		<div class="box-header aligncenter">Actions</div>
		<div class="aligncenter">
			<a href="/running/<?= $testname ?>"><img src="/images/back.png" alt="back" title="back to running page" /></a> 
		</div>
	</div>

	<div class="grid_5 box box-shadow alpha" id="mode_box">
		<div class="box-header aligncenter">Mode Select</div>
		<div class="aligncenter">
			<div style="display: inline-block; text-align: left;">
				<input type="radio" name="mode" value="cropp" id="cropp" checked="checked" onchange="modechange()" /><label for="cropp">Crop Image</label><br />
				<input type="radio" name="mode" value="click" id="click" onchange="modechange()" /><label for="click">Click Location</label>
			</div>
		</div>
	</div>

	<div class="grid_5 box box-shadow alpha" id="cropdetails_box">
		<div class="box-header aligncenter">Cropping details</div>
		<div style="margin: 0 18px 0 0;">
			<form method="post" action="" onsubmit="return checkform(this);">
				<table style="border: none;">
					<tr id="cpi1">
						<td style="width: 60px;">Start Position:</td>
						<td style="width: 65px;">
							<input type="text" name="x1" id="x1" size="1" readonly="readonly" value="0" /> x
							<input type="text" name="y1" id="y1" size="1" readonly="readonly" value="0" />
						</td>
					</tr>
					<tr id="cpi2">
						<td>Size:</td>
						<td>
							<input type="text" name="width" id="width" size="1" readonly="readonly" value="0" /> x
							<input type="text" name="height" id="height" size="1" readonly="readonly" value="0" />
						</td>
					</tr>
					<tr id="cpi3">
						<td>End Position:</td>
						<td>
							<input type="text" name="x2" id="x2" size="1" readonly="readonly" value="0" /> x
							<input type="text" name="y2" id="y2" size="1" readonly="readonly" value="0" />
						</td>
					</tr>
					<tr id="cli1">
						<td>Click Location:</td>
						<td>
							<input type="text" name="xc" id="xc" size="1" readonly="readonly" value="0" /> x
							<input type="text" name="yc" id="yc" size="1" readonly="readonly" value="0" />
						</td>
					</tr>
				</table>
				<br />
				<div class="aligncenter">
					<input type="hidden" name="testname" value="<?= $testname ?>" />
					<input type="hidden" name="testmodule" value="<?= $testmodule ?>" />
					<input type="reset" onclick="resetform();" class="button" value="Reset" />
					<input type="submit" value="Process Image" name="process" />
				</div>
			</form>
			<? if(%$processed) { ?>
			<br /><br />
			<div class="aligncenter">
				<img src="/images/accept.png" width="16" height="16" />
				Image Processed
			</div>
			<table style="border: none;">
				<tr>
					<td style="width: 60px;">Filename:</td>
					<td style="width: 150px;"><?= $processed->{'name'} ?>.ppm</td>
				</tr>
				<tr>
					<td colspan="2">
						<a href="/<?= $perlurl ?>/waitimgs/click/<?= $processed->{'name'} ?>.png"><img src="/<?= $perlurl ?>/waitimgs/click/<?= $processed->{'name'} ?>.png?<?= ($processed->{'width'} > 200 || $processed->{'height'} > 150)?'size=200x150':'' ?>" style="border: 1px dotted #ccc;" /></a>
					</td>
				</tr>
			</table>
			<? } ?>
		</div>
	</div>
</div>

<div class="grid_14 box box-shadow omega">
	<div style="margin: 0 10px; position: relative; background-color: #202020;">
		<img src="/<?= $prj ?>/<?= $imgpath ?>.png" alt="test image" id="testImage" />
		<div class="click-location-pointer" id="click-location-pointer"><div>+</div></div>
	</div>
</div>
? } # endblock content
