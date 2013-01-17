? extends 'fluid'

? my $ref_width=80;
? my $ref_height=int($ref_width/4*3);

? block locbar => sub {
?= super()
&gt; <a href="/refimgs/">Reference Images</a>
<? if($testfilter) { ?>&gt; <?= $testfilter ?><? } ?>
? }

? block content => sub {
<div class="grid_2 box box-shadow alpha" id="audio_box">
	<div class="box-header aligncenter">Audio Files</div>
	<div style="text-align: center;">
		<? if(@$audiofiles) { ?>
		<? for my $wav (@$audiofiles) { ?>
		<a href="/<?= $perlurl ?>/audio/<?= $wav ?>.ogg"><?= $wav ?>.wav</a><br />
		<? } ?>
		<? } else { ?>
		<i>None</i>
		<? } ?>
	</div>
</div>

<div class="grid_14 omega">
	<div class="box box-shadow">
		<div class="box-header aligncenter">Reference Images</div>
		<h2>Images</h2>
		<p>This tool displays all available reference images.</p>
		<table style="width: 95%;">
			<tr>
				<th style="width: 200px;">Test</th>
				<th style="width: 150px;">Screenshot&nbsp;#</th>
				<th style="width: 100%;">Images</th>
			</tr>
			<? cycle(1) ?>
			<? for my $testref (@$testrefs) { ?>
			<tr class="<?= cycle() ?>">
				<td rowspan="<?= scalar(@{$testref->{'screenrefs'}}) ?>" class="component"><?= $testref->{'testmodule'} ?></td>
				<? first_run(1) ?>
				<? for my $screenref (@{$testref->{'screenrefs'}}) { ?>
				<? if(!first_run()) { ?>
				<tr class="<?= cycle(2) ?>">
				<? } ?>
				<td><?= $screenref->{'screenshot'} ?></td>
				<td>
					<? for my $refimg (@{$screenref->{'refimgs'}}) { ?>
					<form method="post" action="/refimgs/<?= $testfilter ?>" onsubmit="return confirm('Delete '+this.delete.value+'?');" style="display: inline;">
						<span class="refpic">
							<a href="/<?= $perlurl ?>/testimgs/<?= $refimg->{'name'} ?>.png"><img src="/<?= $perlurl ?>/testimgs/<?= $refimg->{'name'} ?>.jpg?csize=<?= $ref_width ?>x<?= $ref_height ?>" width="<?= $ref_width ?>" height="<?= $ref_height ?>" alt="<?= $refimg->{'name'} ?>.ppm" title="<?= $refimg->{'name'} ?>.ppm" class="pic" /></a>
							<? if(is_authorized_rw()) { ?>
							<span class="delete-icon"><input type="hidden" name="delete" value="<?= $refimg->{'name'} ?>.ppm" /><input type="image" src="/images/cross.png" alt="X" title="Delete Image" /></span>
							<? } ?>
							<span class="match-icon"><img src="/images/match_icons/<?= $refimg->{'match'} ?>.png" width="16" height="16" alt="<?= $refimg->{'match'} ?>" title="<?= match_title($refimg->{'match'}) ?>" style="border: none;" /></span>
							<span class="result-icon"><img src="/images/<?= ($refimg->{'result'} eq 'good')?'accept.png':'exclamation.png' ?>" width="16" height="16" alt="<?= $refimg->{'result'} ?>" title="<?= $refimg->{'result'} ?>" style="border: none;" /></span>
						</span>
					</form>
					<? } ?>
				</td>
			</tr>
			<? } ?>
			<? } ?>
		</table>
	</div>

	<div class="box box-shadow">
		<div class="box-header aligncenter">Interaction Images</div>
		<h2>Images</h2>
		<p>This tool displays all available wait/click images.</p>
		<table style="width: 95%;">
			<tr>
				<th style="width: 200px;">Test</th>
				<th style="width: 50%;">Wait-Images</th>
				<th style="width: 50%;">Click-Images</th>
			</tr>
			<? cycle(1) ?>
			<? for my $testinteract (@$testinteracts) { ?>
			<tr class="<?= cycle() ?>">
				<td class="component"><?= $testinteract->{'testmodule'} ?></td>
				<td>
					<? for my $waitimg (@{$testinteract->{'waitimgs'}}) { ?>
					<div style="display: inline;">
						<span class="refpic">
							<a href="/<?= $perlurl ?>/waitimgs/<?= $waitimg ?>.png"><img src="/<?= $perlurl ?>/waitimgs/<?= $waitimg ?>.jpg?csize=<?= $ref_width ?>x<?= $ref_height ?>" width="<?= $ref_width ?>" height="<?= $ref_height ?>" alt="<?= $waitimg ?>.ppm" title="<?= $waitimg ?>.ppm" class="pic" /></a>
						</span>
					</div>
					<? } ?>
				</td>
				<td>
					<? for my $clickimg (@{$testinteract->{'clickimgs'}}) { ?>
					<form method="post" action="/refimgs/<?= $testfilter ?>" onsubmit="return confirm('Delete '+this.deleteclick.value+'?');" style="display: inline;">
						<span class="refpic">
							<a href="/<?= $perlurl ?>/waitimgs/click/<?= $clickimg ?>.png"><img src="/<?= $perlurl ?>/waitimgs/click/<?= $clickimg ?>.jpg?csize=<?= $ref_width ?>x<?= $ref_height ?>" width="<?= $ref_width ?>" height="<?= $ref_height ?>" alt="<?= $clickimg ?>.ppm" title="<?= $clickimg ?>.ppm" class="pic" /></a>
							<? if(is_authorized_rw()) { ?>
							<span class="delete-icon"><input type="hidden" name="deleteclick" value="<?= $clickimg ?>.ppm" /><input type="image" src="/images/cross.png" alt="X" title="Delete Image" /></span>
							<? } ?>
						</span>
					</form>
					<? } ?>
				</td>
			</tr>
			<? } ?>
		</table>
	</div>
</div>
? } # endblock content
