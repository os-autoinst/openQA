? extends 'defstyle-18'

? my $ref_width=80;
? my $ref_height=int($ref_width/4*3);

? block additional_headlines => sub {
<script src="/static/prototype.js" type="text/javascript"></script>
<script src="/static/scriptaculous/scriptaculous.js" type="text/javascript"></script>
<script src="/static/cropper.uncompressed.js" type="text/javascript"></script>
<script src="/static/crop.js" type="text/javascript"></script>
<script type="text/javascript">
<!--
var initcoords = <?= (%$cropped)?encoded_string("{ x1: $cropped->{'x1'}, y1: $cropped->{'y1'}, x2: $cropped->{'x2'}, y2: $cropped->{'y2'} }"):'0' ?>;

Event.observe(window, "load", cropinit);

document.onclick = function(e) {
	if(!e) e=window.event;
	elem = getEventTarget(e);
	if(elem.nodeName == "BODY" || elem.nodeName == "HTML") {
		crpr.options.onloadCoords=null;
		crpr.reset();
	}
}

function checkform(f) {
	if(
	! isvalnum(f.x2.value) ||
	! isvalnum(f.y2.value) ||
	! isvalnum(f.width.value) ||
	! isvalnum(f.height.value) ) {
		alert("Make your selection first!");
		return false;
	}

	if(!f.result[0].checked && !f.result[1].checked) {
		alert("Select a result first!");
		return false;
	}
	if(!f.match[0].checked && !f.match[1].checked && !f.match[2].checked && !f.match[3].checked) {
		alert("Select a matching method first!");
		return false;
	}
	return true;
}

function resetform() {
	crpr.options.onloadCoords=null;
	crpr.reset();
	$("good").defaultChecked = false;
	$("bad").defaultChecked = false;
	$("strict").defaultChecked = false;
	$("diff").defaultChecked = false;
	$("hwfuzzy").defaultChecked = true;
	$("fuzzy").defaultChecked = false;
}
-->
</script>
? }

? block locbar => sub {
?= super()
&gt; <a href="/refimgs/">Crop Image</a>
&gt; <a href="/results/<?= $testname ?>"><?= $testname ?></a>
&gt; <?= $imgname ?>
? }

? block content => sub {
<div class="grid_5 box box-shadow alpha" id="cropdetails_box">
	<div class="box-header aligncenter">Cropping details</div>
	<div style="margin: 0 18px 0 0;">
		<form method="post" action="" onsubmit="return checkform(this);">
			<table style="border: none;">
				<tr>
					<td style="width: 60px;">Start Position:</td>
					<td style="width: 65px;">
						<input type="text" name="x1" id="x1" size="1" readonly="readonly" value="0" /> x
						<input type="text" name="y1" id="y1" size="1" readonly="readonly" value="0" />
					</td>
				</tr>
				<tr>
					<td>Size:</td>
					<td>
						<input type="text" name="width" id="width" size="1" readonly="readonly" value="0" /> x
						<input type="text" name="height" id="height" size="1" readonly="readonly" value="0" />
					</td>
				</tr>
				<tr>
					<td>End Position:</td>
					<td>
						<input type="text" name="x2" id="x2" size="1" readonly="readonly" value="0" /> x
						<input type="text" name="y2" id="y2" size="1" readonly="readonly" value="0" />
					</td>
				</tr>
				<tr>
					<td>Result:</td>
					<td style="text-align: left; padding-left: 15px;">
						<input type="radio" name="result" id="good" value="good"<?= (defined $cropped->{'result'} && $cropped->{'result'} eq 'good')?encoded_string(' checked="checked"'):'' ?> />
						<label for="good" class="resultok" style="display: inline-block; width: 3em; text-align: center;">Good</label>
						<br />
						<input type="radio" name="result" id="bad" value="bad"<?= (defined $cropped->{'result'} && $cropped->{'result'} eq 'bad')?encoded_string(' checked="checked"'):'' ?> />
						<label for="bad" class="resultfail" style="display: inline-block; width: 3em; text-align: center;">Bad</label>
					</td>
				</tr>
				<tr>
					<td>Match:</td>
					<td style="text-align: left; padding-left: 15px;">
						<input type="radio" name="match" id="strict" value="strict"<?= (defined $cropped->{'match'} && $cropped->{'match'} eq 'strict')?encoded_string(' checked="checked"'):'' ?> title="<?= match_title('strict') ?>" />
						<label for="strict" title="<?= match_title('strict') ?>">Strict</label>
						<br />
						<input type="radio" name="match" id="diff" value="diff"<?= (defined $cropped->{'match'} && $cropped->{'match'} eq 'diff')?encoded_string(' checked="checked"'):'' ?> title="<?= match_title('diff') ?>" />
						<label for="bytediff" title="<?= match_title('diff') ?>">Byte-Diff</label>
						<br />
						<input type="radio" name="match" id="hwfuzzy" value="hwfuzzy"<?= (defined $cropped->{'match'} && $cropped->{'match'} eq 'hwfuzzy' || !defined $cropped->{'match'})?encoded_string(' checked="checked"'):'' ?> title="<?= match_title('hwfuzzy') ?>" />
						<label for="hwfuzzy" title="<?= match_title('hwfuzzy') ?>">HW-Fuzzy</label>
						<br />
						<input type="radio" name="match" id="fuzzy" value="fuzzy"<?= (defined $cropped->{'match'} && $cropped->{'match'} eq 'fuzzy')?encoded_string(' checked="checked"'):'' ?> title="<?= match_title('fuzzy') ?>" />
						<label for="fuzzy" title="<?= match_title('fuzzy') ?>">Fuzzy</label>
					</td>
				</tr>
			</table>
			<br />
			<div class="aligncenter">
				<input type="reset" onclick="resetform();" class="button" value="Reset" />
				<input type="submit" value="Crop Image" />
			</div>
		</form>
		<? if(%$cropped) { ?>
		<br /><br />
		<div class="aligncenter">
			<img src="/images/accept.png" width="16" height="16" />
			Image Cropped
		</div>
		<table style="border: none;">
			<tr>
				<td style="width: 60px;">Filename:</td>
				<td style="width: 150px;"><?= $cropped->{'name'} ?>.ppm</td>
			</tr>
			<tr>
				<td colspan="2">
					<a href="/<?= $perlurl ?>/testimgs/<?= $cropped->{'name'} ?>.png"><img src="/<?= $perlurl ?>/testimgs/<?= $cropped->{'name'} ?>.png?<?= ($cropped->{'width'} > 200 || $cropped->{'height'} > 150)?'size=200x150':'' ?>" style="border: 1px dotted #ccc;" /></a>
				</td>
			</tr>
		</table>
		<? } ?>
	</div>
</div>

<div class="grid_14 box box-shadow omega">
	<div style="margin: 0 10px; background-color: #202020;">
		<img src="/<?= $prj ?>/testresults/<?= $testname ?>/<?= $imgname ?>.png" alt="test image" id="testImage" />
	</div>
</div>

<div class="grid_5 box box-shadow alpha">
	<div class="box-header aligncenter">Test details</div>
	<div style="margin: 0 18px 0 0;">
		<table style="border: none;">
			<tr>
				<td style="width: 60px;">Test:</td>
				<td style="width: 65px;">
					<select name="testlist" id="testlist" onchange="self.location.href='/cropimg/<?= $prj ?>/testresults/<?= $testname ?>/'+this.value+'-1.png';">
						<? for my $test (@$testlist) { ?>
						<option value="<?= $test ?>"<?= ($test eq $testmodule)?encoded_string(' selected="selected"'):'' ?>><?= $test ?></option>
						<? } ?>
					</select>
				</td>
			</tr>
			<tr>
				<td>Result:</td>
				<td class="result<?= "\L$testresult" ?>"><?= $testresult ?> <?= $refimg_result ?></td>
			</tr>
		</table>
	</div>
</div>

<div class="grid_14 box box-shadow omega">
	<div style="margin: 0 20px; overflow-x: scroll; overflow-y: hidden; overflow: auto; white-space: nowrap;">
		<? for my $screenshot (@$imglist) { ?>
		<a href="/cropimg/<?= $prj ?>/testresults/<?= $testname ?>/<?= $screenshot ?>.png"><img src="/<?= $prj ?>/testresults/<?= $testname ?>/<?= $screenshot ?>.jpg?csize=<?= $ref_width ?>x<?= $ref_height ?>" width="<?= $ref_width ?>" height="<?= $ref_height ?>" alt="<?= $screenshot ?>" title="<?= $screenshot ?>" class="pic <?= ($screenshot eq $imgname)?'crop-screenshot-current':'crop-screenshot' ?>" /></a>
		<? } ?>
	</div>
</div>
? } # endblock content
