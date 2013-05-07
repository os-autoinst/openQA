? extends 'defstyle'

? my $ref_width=80;
? my $ref_height=int($ref_width/4*3);

? block locbar => sub {
?= super()
&gt; View Image
&gt; <a href="/results/<?= $testname ?>"><?= $testname ?></a>
&gt; <?= $testmodule ?>
? }

? block content => sub {
<div class="grid_2 box box-shadow alpha" id="actions_box">
	<div class="box-header aligncenter">Actions</div>
	<div class="aligncenter">
		<? if(is_authorized_rw()) { ?>
		<a href="/cropimg/<?= $prj ?>/testresults/<?= $testname ?>/<?= $imgname ?>"><img src="/images/edit.png" alt="crop" title="Crop Image" /></a>
		<? } ?>
		<a href="/results/<?= $testname ?>"><img src="/images/back.png" alt="back" title="back to overview page" /></a> 
	</div>
</div>

<div class="grid_14 alpha">
	<div class="grid_14 box box-shadow omega">
		<div class="box-header aligncenter"><?= $imgname ?></div>
		<div style="margin: 0 10px; position: relative; width: 800px; height: 600px;">
			<a href="/<?= $prj ?>/testresults/<?= $testname ?>/<?= $imgname ?>">
				<img src="/<?= $prj ?>/testresults/<?= $testname ?>/<?= $imgname ?>?fixsize=1" width="800" height="600"
				alt="<?= $imgname ?>" style="position: absolute; z-index: 2;" />
				<? if (1) { ?>
				<script type="text/javascript">
					var refpos_x = <?= $screenshot->{'x'} ?>;
					var refpos_y = <?= $screenshot->{'y'} ?>;
					var ref_x = <?= $screenshot->{'w'} ?>;
					var ref_y = <?= $screenshot->{'h'} ?>;
					var scr_x = <?= $img_width ?>;
					var scr_y = <?= $img_height ?>;
					if(scr_x > 800 || scr_y > 600) {
						refpos_x = (refpos_x / scr_x) * 800;
						refpos_y = (refpos_y / scr_y) * 600;
						ref_x = (ref_x / scr_x) * 800;
						ref_y = (ref_y / scr_y) * 600;
					}
					document.write('<canvas id="cmatch" class="cmatch" width="800" height="600" style="position: absolute; z-index: 3;"></canvas>');
					var canvas = document.getElementById('cmatch');
					var context = canvas.getContext('2d');
					//context.beginPath();
					context.lineWidth = 3;
					context.strokeStyle = 'rgb(34,120,8)';
					context.strokeRect(refpos_x, refpos_y, ref_x, ref_y);
                                        context.fillStyle = 'rgba(151, 208, 5, .5)';
					context.fillRect(refpos_x, refpos_y, ref_x, ref_y);
                                        context.font = "14pt sans-serif";
                                        context.fillStyle = 'rgb(34,120,8)';
                                        context.fillText("X.XXXXX", refpos_x, refpos_y);
					//context.stroke();
				</script>
				<? } ?>
			</a>
		</div>
	</div>

	<? if(@$imglist) {
             my $img_count = 1; ?>
	<div class="grid_14 box box-shadow omega">
		<div style="margin: 0 20px; overflow-x: scroll; overflow-y: hidden; overflow: auto; white-space: nowrap;">
			<? for my $refimg (@$imglist) { ?>
			<span class="refcomppic <?= ($screenshot->{'refimg'} and $refimg->{'id'} eq $screenshot->{'refimg'}->{'id'})?'match':'' ?>">
				<a href="<?= $img_count++ ?>"><img
					src="/<?= $prj ?>/testresults/<?= $testname ?>/<?= $refimg->{'screenshot'} ?>?size=<?= $ref_width ?>x<?= $ref_height ?>"
					width="<?= $ref_width ?>" height="<?= $ref_height ?>" alt="<?= $refimg->{'name'} ?>.png" title="<?= $refimg->{'name'} ?>.png"
					class="<?= "resborder\L$refimg->{'result'}" ?>" /></a>
			</span>
			<? } ?>
		</div>
	</div>
	<? } ?>
</div>
? } # endblock content
