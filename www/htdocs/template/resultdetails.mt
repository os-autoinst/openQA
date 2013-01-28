? extends 'fluid'

? block additional_headlines => sub {
<style type="text/css">
<!--
.infotbl td {
	padding: 0 0 0 0;
}
.infotbl img {
	padding-right: 3px;
}
-->
</style>
? }

? my $ref_width=60;
? my $ref_height=int($ref_width/4*3);

? block locbar => sub {
?= super()
&gt; <a href="/results/">Results</a>
&gt; <?= $testname ?>
? }

? block content => sub {
<div class="grid_2 alpha">
	<div class="box box-shadow" id="actions_box">
		<div class="box-header aligncenter">Actions</div>
		<div class="aligncenter">
			<? if($diskimg) { ?>
			<a href="/diskimg/<?= $testname ?>/l1.gz"><img width="23" height="23" src="/images/floppy.png" alt="img" title="download disk image"/></a>
			<? } ?>
			<a href="/<?= $prj ?>/video/<?= $testname ?>.ogv"><img width="23" height="23" src="/images/video.png" alt="ogv" title="ogg/theora video of this testrun"/></a>
			<a href="/<?= $prj ?>/video/<?= $testname ?>.ogv.autoinst.txt"><img width="23" height="23" src="/images/log.png" alt="log" title="complete log of this testrun"/></a>
			<a href="/<?= $prj ?>/logs/<?= $testname ?>.tar.bz2"><img width="23" height="23" src="/images/download.png" alt="logs" title="download var/log.tar.bz2"/></a>
			<a href="/results/"><img src="/images/back.png" alt="back" title="back to overview page" /></a>
		</div>
	</div>
	<? if($backend_info) { ?>
	<? $backend_info->{'backend'} =~s/^.*:://; ?>
	<div class="box box-shadow" id="backend_info_box">
		<div class="box-header aligncenter">Backend</div>
		<div style="margin: 0 3px 0 3px;" class="cligncenter">
			<table style="border: none; margin: 0;" class="infotbl">
				<tr>
					<td colspan="2" style="padding: 0 0 <?= ($backend_info->{'backend'} eq 'kvm2usb')?'8px':'0' ?> 0;"><?= $backend_info->{'backend'} ?></td>
				</tr>
				<? if($backend_info->{'backend'} eq 'kvm2usb') { ?>
					<tr>
						<td style="width: 16px;"><img src="/images/hw_icons/slot.svg" width="16" height="16" title="slot" alt="slot"/></td>
						<td><?= $backend_info->{'backend_info'}->{'hwslot'} ?></td>
					</tr>
					<? if(defined $backend_info->{'backend_info'}->{'hw_info'}) { ?>
						<? my $hw_info = $backend_info->{'backend_info'}->{'hw_info'}; ?>
						<? for my $hw_key ( ('vendor', 'name', 'cpu', 'cpu_cores', 'memory', 'disks') ) { ?>
							<? next unless defined $hw_info->{$hw_key} ?>
							<tr>
								<td><img src="/images/hw_icons/<?= $hw_key ?>.svg" title="<?= $hw_key ?>" width="16" height="16" alt="<?= $hw_key ?>" /></td>
								<td><?= $hw_info->{$hw_key} ?></td>
							</tr>
						<? } ?>
						<? if(defined $hw_info->{'comment'}) { ?>
							<tr>
								<td colspan="2" style="padding: 8px 0 0 0;"><?= $hw_info->{'comment'} ?></td>
							</tr>
						<? } ?>
					<? } ?>
				<? } ?>
			</table>
		</div>
	</div>
	<? } ?>
</div>

<div class="grid_14 omega">
	<div class="box box-shadow">
		<h2>Results</h2>
		<p>This tool displays details on one particular test result.</p>
		<p />
		<table style="width: 95%;">
			<tr>
				<th style="width: 200px;" colspan="2">Test</th>
				<th style="width: 150px; padding: 0 25px;">Result</th>
				<th colspan="3">References</th>
			</tr>
			<? cycle(1) ?>
			<? for my $module (@$modlist) { ?>
			<tr class="<?= cycle() ?>">
				<td class="info" style="width: 1em;"><?= $module->{'refimg'}?encoded_string('&#10063;'):'' ?> <?= $module->{'audio'}?encoded_string('&#9835;'):'' ?> <?= $module->{'ocr'}?encoded_string('&#7425;'):'' ?></td>
				<td class="component"><? unless($module->{'name'}=~m/timeout|standstill|isosize|overall/) { ?><a href="/tdata/show/<?= $testname ?>/<?= $module->{'name'} ?>"><?= $module->{'name'} ?></a><? } else { ?><?= $module->{'name'} ?><? } ?></td>
				<td class="<?= "result$res_css->{$module->{'result'}}" ?>"><?= $res_display->{$module->{'result'}} ?></td>
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
</div>
? } # endblock content
