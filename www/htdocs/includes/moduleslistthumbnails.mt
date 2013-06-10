<? if(@$imglist) {
	my $img_count = 1;
	my $ref_width=80;
	my $ref_height=int($ref_width/4*3); ?>

	<div class="box box-shadow">
		<div style="margin: 0 6px; overflow-x: scroll; overflow-y: hidden; overflow: auto; white-space: nowrap;">
			<? for my $refimg (@$imglist) { ?>
			<span class="<?= ($img_count == $testindex) ? "thumbnail current" : "thumbnail" ?>">
				<? if($refimg->{'screenshot'}) { ?>
					<a href="<?= "/".(($action eq 'viewaudio')?'viewimg':$action)."/show/$testname/$testmodule/".$img_count ?>">
						<img src="/<?= $prj ?>/testresults/<?= $testname ?>/<?= $refimg->{'screenshot'} ?>?size=<?= $ref_width ?>x<?= $ref_height ?>"
						alt="<?= $refimg->{'screenshot'} ?>" title="<?= $refimg->{'screenshot'} ?>"
						width="<?= $ref_width ?>" height="<?= $ref_height ?>" class="<?= "resborder\L$refimg->{'result'}" ?>" />
				<? } elsif ($refimg->{'audio'}) { ?>
					<a href="<?= "/".(($action eq 'viewsrc')?$action:'viewaudio')."/show/$testname/$testmodule/".$img_count ?>">
						<img src="/images/audio.svg"
						alt="<?= $refimg->{'audio'} ?>" title="<?= $refimg->{'audio'} ?>"
						width="<?= $ref_width ?>" height="<?= $ref_height ?>" class="<?= "resborder\L$refimg->{'result'}" ?>" />
				<? } ?>
					</a>
			</span>
			<? $img_count++ ?>
			<? } ?>
		</div>
	</div>
<? } ?>
