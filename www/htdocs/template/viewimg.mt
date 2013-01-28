? extends 'defstyle'

? my $ref_width=80;
? my $ref_height=int($ref_width/4*3);

? block locbar => sub {
?= super()
&gt; View Image
&gt; <a href="/results/<?= $testname ?>"><?= $testname ?></a>
&gt; <?= $imgname ?>
? }

? block content => sub {
<div class="grid_2 box box-shadow alpha" id="actions_box">
	<div class="box-header aligncenter">Actions</div>
	<div class="aligncenter">
		<? if(is_authorized_rw()) { ?>
		<a href="/cropimg/<?= $prj ?>/testresults/<?= $testname ?>/<?= $imgname ?>.png"><img src="/images/edit.png" alt="crop" title="Crop Image" /></a>
		<? } ?>
		<a href="/results/<?= $testname ?>"><img src="/images/back.png" alt="back" title="back to overview page" /></a> 
	</div>
</div>

<div class="grid_14 alpha">
	<div class="grid_14 box box-shadow omega">
		<div class="box-header aligncenter"><?= $imgmd5 ?></div>
		<div style="margin: 0 10px; position: relative; width: 800px; height: 600px;">
			<a href="/<?= $prj ?>/testresults/<?= $testname ?>/<?= $imgname ?>.png">
				<img src="/<?= $prj ?>/testresults/<?= $testname ?>/<?= $imgname ?>.png?fixsize=1" width="800" height="600"
				alt="<?= $imgname ?>" style="position: absolute; z-index: 2;" />
				<? if ($screenshot->{'refimg'}) { ?>
				<script type="text/javascript">
					var refpos_x = <?= $screenshot->{'refimg'}->{'match'}->[0] ?>;
					var refpos_y = <?= $screenshot->{'refimg'}->{'match'}->[1] ?>;
					var ref_x = <?= $screenshot->{'refimg'}->{'size'}->[0] ?>;
					var ref_y = <?= $screenshot->{'refimg'}->{'size'}->[1] ?>;
					var scr_x = <?= $screenshot->{'size'}->[0] ?>;
					var scr_y = <?= $screenshot->{'size'}->[1] ?>;
					if(scr_x > 800 || scr_y > 600) {
						refpos_x = (refpos_x / scr_x) * 800;
						refpos_y = (refpos_y / scr_y) * 600;
						ref_x = (ref_x / scr_x) * 800;
						ref_y = (ref_y / scr_y) * 600;
					}
					document.write('<canvas id="cmatch" class="cmatch" width="800" height="600" style="position: absolute; z-index: 3;"></canvas>');
					var canvas = document.getElementById('cmatch');
					var context = canvas.getContext('2d');
					context.beginPath();
					context.rect(refpos_x, refpos_y, ref_x, ref_y);
					context.lineWidth = 3;
					context.strokeStyle = '#3399CC';
					context.stroke();
				</script>
				<? } ?>
			</a>
		</div>
	</div>

	<? if(@$imglist) { ?>
	<div class="grid_14 box box-shadow omega">
		<div style="margin: 0 20px; overflow-x: scroll; overflow-y: hidden; overflow: auto; white-space: nowrap;">
			<? for my $refimg (@$imglist) { ?>
			<span class="refcomppic <?= ($screenshot->{'refimg'} and $refimg->{'id'} eq $screenshot->{'refimg'}->{'id'})?'match':'' ?>">
				<a href="/<?= $perlurl ?>/testimgs/<?= $refimg->{'name'} ?>.png"><img
					src="/<?= $perlurl ?>/testimgs/<?= $refimg->{'name'} ?>.jpg?csize=<?= $ref_width ?>x<?= $ref_height ?>"
					width="<?= $ref_width ?>" height="<?= $ref_height ?>" alt="<?= $refimg->{'name'} ?>.ppm" title="<?= $refimg->{'name'} ?>.ppm"
					class="pic" /></a>
				<span class="match-icon"><img src="/images/match_icons/<?= $refimg->{'match'} ?>.png" width="16" height="16" alt="<?= $refimg->{'match'} ?>" title="<?= match_title($refimg->{'match'}) ?>" style="border: none;" /></span>
				<span class="result-icon"><img src="/images/<?= ($refimg->{'result'} eq 'good')?'accept.png':'exclamation.png' ?>" width="16" height="16" alt="<?= $refimg->{'result'} ?>" title="<?= $refimg->{'result'} ?>" style="border: none;" /></span>
			</span>
			<? } ?>
		</div>
	</div>
	<? } ?>
</div>
? } # endblock content
