? extends 'defstyle-18'

? my $ref_width=80;
? my $ref_height=int($ref_width/4*3);

? block additional_headlines => sub {
<script src="/static/keyevent.js"></script>
<script src="/static/shapes.js"></script>
<script src="/static/needleeditor.js"></script>
<script type="text/javascript">
<!--
window.onload=function(){ 
  new NeedleEditor('<?= $needle ?>');
};
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
	<div id="needleeditor_tags" style="margin: 0 18px 0 0;"></div>
        <form method="post" action="">
          <textarea id="needleeditor_textarea" name="json" readOnly="yes" style="width:97%; height:300px;"></textarea>
          <input type="submit" value="Save" />
        </form>
</div>

<div class="grid_14 box box-shadow omega">
	<div style="margin: 0 10px; background-color: #202020;">
             <canvas tabindex="1" id="needleeditor_canvas" width="1024" height="768" style="border: 1px solid black;">
             This text is displayed if your browser does not support HTML5 Canvas.
             </canvas>
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
