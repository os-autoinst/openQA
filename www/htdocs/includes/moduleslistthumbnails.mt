<? if(@$imglist) {
	my $img_count = 1;
	my $ref_width=80;
	my $ref_height=int($ref_width/4*3); ?>

	<div class="box box-shadow">
		<div style="margin: 0 6px; overflow-x: scroll; overflow-y: hidden; overflow: auto; white-space: nowrap;">
			<? for my $refimg (@$imglist) { ?>
			<span class="<?= ($img_count == $testindex) ? "thumbnail current" : "thumbnail" ?>">
				<a href="<?= $img_count++ ?>">
					<img src="/<?= $prj ?>/testresults/<?= $testname ?>/<?= $refimg->{'screenshot'} ?>?size=<?= $ref_width ?>x<?= $ref_height ?>"
					width="<?= $ref_width ?>" height="<?= $ref_height ?>" alt="<?= $refimg->{'name'} ?>.png" title="<?= $refimg->{'name'} ?>.png"
					class="<?= "resborder\L$refimg->{'result'}" ?>" /></a>
			</span>
			<? } ?>
		</div>
	</div>
<? } ?>
