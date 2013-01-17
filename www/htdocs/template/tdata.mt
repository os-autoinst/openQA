? extends 'fluid'

? my $ref_width=80;
? my $ref_height=int($ref_width/4*3);

? block additional_headlines => sub {
<link href="/static/perltidy.css" rel="stylesheet" type="text/css" />
<style type="text/css">
	tt,pre {
		font-family: "monospace", monospace;
		font-size: 90%;
	}
</style>
? }

? block locbar => sub {
?= super()
&gt; <a href="/refimgs/">Test Data</a>
&gt; <?= $testmodule ?>
? }

? block content => sub {
<div class="grid_2 alpha">
	<div class="box box-shadow alpha" id="actions_box">
		<div class="box-header aligncenter">Actions</div>
		<div class="aligncenter">
			<a href='/tdata/raw/<?= $testname ?>/<?= $testmodule ?>'><img src='/images/log.png' alt='raw test' title='raw test' height='23' width='23' /></a>
			<? if($running) { ?>
			<a href="/running/<?= $testname ?>"><img src="/images/back.png" alt="back to running test" title="back to running test" height="22" width="23" /></a>
			<? } else { ?>
			<a href="/results/<?= $testname ?>"><img src="/images/back.png" alt="back to result details" title="back to result details" height="22" width="23" /></a>
			<? } ?>
		</div>
	</div>
	<? if(@$audiofiles) { ?>
	<div class="box box-shadow alpha" id="audio_box">
		<div class="box-header aligncenter">Audio Files</div>
		<div style="text-align: center;">
			<? for my $wav (@$audiofiles) { ?>
			<a href="/<?= $perlurl ?>/audio/<?= $wav ?>.ogg"><?= $wav ?>.wav</a><br />
			<? } ?>
		</div>
	</div>
	<? } ?>
	<? if(@$waitimgs) { ?>
	<div class="box box-shadow alpha" id="wait_box">
		<div class="box-header aligncenter">Wait Images</div>
		<div style="text-align: center; line-height: 0.5em;">
			<? first_run(1) ?>
			<? for my $wimg (@$waitimgs) { ?>
			<? if(!first_run()) { ?><br /><br /><? } ?>
			<div style="display: inline-block;">
				<span class="refpic">
					<a href="/<?= $perlurl ?>/waitimgs/<?= $wimg ?>.png"><img src="/<?= $perlurl ?>/waitimgs/<?= $wimg ?>.jpg?csize=<?= $ref_width ?>x<?= $ref_height ?>" width="<?= $ref_width ?>" height="<?= $ref_height ?>" alt="<?= $wimg ?>.ppm" title="<?= $wimg ?>.ppm" class="pic" /></a>
				</span>
			</div>
			<? } ?>
		</div>
	</div>
	<? } ?>
	<? if(@$clickimgs) { ?>
	<div class="box box-shadow alpha" id="click_box">
		<div class="box-header aligncenter">Click Images</div>
		<div style="text-align: center; line-height: 0.5em;">
			<? first_run(1) ?>
			<? for my $cimg (@$clickimgs) { ?>
			<? if(!first_run()) { ?><br /><br /><? } ?>
			<form method="post" action="/tdata/show/<?= $testname ?>/<?= $testmodule ?>" onsubmit="return confirm('Delete '+this.deleteclick.value+'?');" style="display: inline-block;">
				<span class="refpic">
					<a href="/<?= $perlurl ?>/waitimgs/click/<?= $cimg ?>.png"><img src="/<?= $perlurl ?>/waitimgs/click/<?= $cimg ?>.jpg?csize=<?= $ref_width ?>x<?= $ref_height ?>" width="<?= $ref_width ?>" height="<?= $ref_height ?>" alt="<?= $cimg ?>.ppm" title="<?= $cimg ?>.ppm" class="pic" /></a>
					<? if(is_authorized_rw()) { ?>
					<span class="delete-icon"><input type="hidden" name="deleteclick" value="<?= $cimg ?>.ppm" /><input type="image" src="/images/cross.png" alt="X" title="Delete Image" /></span>
					<? } ?>
				</span>
			</form>
			<? } ?>
		</div>
	</div>
	<? } ?>
</div>

<div class="grid_14 omega">
	<? if(@$screenrefs) { ?>
	<div class="box box-shadow">
		<div class="box-header aligncenter">Reference Images</div>
		<h2>Images</h2>
		<p>This are the available reference images for the <i><?= $testmodule ?></i> test.</p>
		<table style="width: 95%;">
			<tr>
				<th style="width: 150px;">Screenshot&nbsp;#</th>
				<th style="width: 100%;">Images</th>
			</tr>
			<? cycle(1) ?>
			<? for my $screenref (@$screenrefs) { ?>
			<tr class="<?= cycle() ?>">
				<td><?= $screenref->{'screenshot'} ?></td>
				<td>
					<? for my $refimg (@{$screenref->{'refimgs'}}) { ?>
					<form method="post" action="/tdata/show/<?= $testname ?>/<?= $testmodule ?>" onsubmit="return confirm('Delete '+this.delete.value+'?');" style="display: inline;">
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
		</table>
	</div>
	<? } ?>
	<div class="box box-shadow">
		<div class="box-header aligncenter">Test Script</div>
		<h2>Test Source</h2>
		<p>
			This is the <b><?= $testmodule ?></b> test for <b><?= $testname ?></b>
			<br />
			<br />
			Test-Module: <tt><?= $scriptpath ?></tt>
		</p>
		<?= encoded_string syntax_highlight($scriptsrc) ?>
	</div>
</div>
? } # endblock content
