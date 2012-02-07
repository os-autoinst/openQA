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
		<div style="margin: 0 10px;">
			<a href="/<?= $prj ?>/testresults/<?= $testname ?>/<?= $imgname ?>.png"><img src="/<?= $prj ?>/testresults/<?= $testname ?>/<?= $imgname ?>.png?fixsize=1" width="800" height="600" alt="<?= $imgname ?>" /></a>
		</div>
	</div>

	<? if(@$imglist) { ?>
	<div class="grid_14 box box-shadow omega">
		<div style="margin: 0 20px; overflow-x: scroll; overflow-y: hidden; overflow: auto; white-space: nowrap;">
			<? for my $refimg (@$imglist) { ?>
			<span class="refcomppic">
				<a href="/<?= $perlurl ?>/testimgs/<?= $refimg->{'name'} ?>.png"><img src="/<?= $perlurl ?>/testimgs/<?= $refimg->{'name'} ?>.jpg?csize=<?= $ref_width ?>x<?= $ref_height ?>" width="<?= $ref_width ?>" height="<?= $ref_height ?>" alt="<?= $refimg->{'name'} ?>.ppm" title="<?= $refimg->{'name'} ?>.ppm" style="padding: 1px;" class="pic" /></a>
				<span class="result-icon"><img src="/images/<?= ($refimg->{'result'} eq 'good')?'accept.png':'exclamation.png' ?>" width="16" height="16" alt="<?= $refimg->{'result'} ?>" title="<?= $refimg->{'result'} ?>" style="border: none;" /></span>
			</span>
			<? } ?>
		</div>
	</div>
	<? } ?>
</div>
? } # endblock content
