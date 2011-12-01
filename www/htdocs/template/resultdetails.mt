? extends 'fluid'

? my $ref_width=60;
? my $ref_height=int($ref_width/4*3);

? block locbar => sub {
?= super()
&gt; <a href="/results/">Results</a>
&gt; <?= $testname ?>
? }

? block content => sub {
<div class="grid_2 box box-shadow alpha" id="actions_box">
	<div class="box-header aligncenter">Actions</div>
	<div class="aligncenter">
		<a href="/<?= $prj ?>/video/<?= $testname ?>.ogv"><img width="23" height="23" src="/images/video.png" alt="ogv" title="ogg/theora video of this testrun"/></a>
		<a href="/<?= $prj ?>/video/<?= $testname ?>.ogv.autoinst.txt"><img width="23" height="23" src="/images/log.png" alt="log" title="complete log of this testrun"/></a>
		<a href="/<?= $prj ?>/logs/<?= $testname ?>.tar.bz2"><img width="23" height="23" src="/images/download.png" alt="logs" title="download var/log.tar.bz2"/></a>
		<a href="/results/"><img src="/images/back.png" alt="back" title="back to overview page" /></a>
	</div>
</div>
<div class="grid_14 box box-shadow omega">
	<h2>Results</h2>
	<p>This tool displays details on one particular test result.</p>
	<p />
	<table style="width: 95%;">
		<tr>
			<th style="width: 200px;" colspan="2">Test</th>
			<th style="width: 150px;">Result</th>
			<th colspan="3">References</th>
		</tr>
		<? cycle(1) ?>
		<? for my $module (@$modlist) { ?>
		<tr class="<?= cycle() ?>">
			<td class="info" style="width: 1em;"><?= $module->{'refimg'}?encoded_string('&#10063;'):'' ?> <?= $module->{'audio'}?encoded_string('&#9835;'):'' ?> <?= $module->{'ocr'}?encoded_string('&#7425;'):'' ?></td>
			<td class="component"><? if($module->{'name'} ne 'timeout') { ?><a href="/tdata/show/<?= $testname ?>/<?= $module->{'name'} ?>"><?= $module->{'name'} ?></a><? } else { ?><?= $module->{'name'} ?><? } ?></td>
			<td class="<?= "result\L$module->{'result'}" ?>"><?= $module->{'result'} ?></td>
			<td class="links" style="width: 60%;">
				<? for my $screenshot (@{$module->{'screenshots'}}) { ?>
				<a href="/viewimg/<?= $prj ?>/testresults/<?= $testname ?>/<?= $screenshot->{'name'} ?>.png" title="<?= $screenshot->{'name'} ?>.ppm"><img src="/<?= $prj ?>/testresults/<?= $testname ?>/<?= $screenshot->{'name'} ?>.png?size=<?= $ref_width ?>x<?= $ref_height ?>" width="<?= $ref_width ?>" height="<?= $ref_height ?>" alt="<?= $screenshot->{'name'} ?>.ppm" class="<?= "resborder\L$screenshot->{'result'}" ?>" /></a>
				<? } ?>
			</td>
			<td class="links" style="width: 20%;">
				<? for my $wav (@{$module->{'wavs'}}) { ?>
				<a href="/<?= $prj ?>/testresults/<?= $testname ?>/<?= $wav->{'name'} ?>.ogg" title="<?= $wav->{'name'} ?>.wav"><img src="/images/audio.png" width="28" height="26" alt="<?= $wav->{'name'} ?>.wav" class="<?= "resborder\L$wav->{'result'}" ?>" /></a>
				<? } ?>
			</td>
			<td class="links" style="width: 20%;">
				<? for my $ocr (@{$module->{'ocrs'}}) { ?>
				<a href="/<?= $prj ?>/testresults/<?= $testname ?>/<?= $ocr->{'name'} ?>.txt" title="<?= $ocr->{'name'} ?>.txt"><img src="/images/text.png" width="26" height="26" alt="<?= $ocr->{'name'} ?>.txt" class="<?= "resborder\L$ocr->{'result'}" ?>" /></a>
				<? } ?>
			</td>
		</tr>
		<? } ?>
	</table>
</div>
? } # endblock content
