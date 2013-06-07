? extends 'defstyle-18'

? block additional_headlines => sub {
<script src="/static/prototype.js" type="text/javascript"></script>
<script src="/static/scriptaculous/scriptaculous.js" type="text/javascript"></script>
<script src="/static/openqa.js" type="text/javascript"></script>
<script src="/static/running.js" type="text/javascript"></script>
<style type="text/css">
<!--
/*
table {
	border: none;
	margin: 0;
	font-family: "monospace", monospace;
	font-size: 10.5667px;
	line-height: 13px;
}
*/

.infotbl td {
	padding: 0 0 0 0;
}
.infotbl img {
	padding-right: 3px;
}
-->
</style>
? }

? block locbar => sub {
?= super()
&gt; <a href="/results/">Running Tests</a>
&gt; <?= $testname ?>
? }

? block content => sub {
<div class="grid_5 alpha">
	<div class="grid_5 box box-shadow alpha" id="actions_box">
		<div class="box-header aligncenter">Actions</div>
		<div class="aligncenter">
			<a href="/results/"><img src="/images/back.png" alt="back" title="back to result page" /></a> 
		</div>
		<table style="width: 90%">
			<tr>
				<td style="width: 8em; padding: 0;">Interactive:</td>
				<td style="width: 4.5em; padding: 0;" id="interactive_indicator" data-next-status="">Unknown</td>
				<td style="padding: 0;" id="needinput_buttons">
					<a href="javascript:window.toggleInteractive()" style="display:none" id="interactive_button"><img src="/images/toggle.png" alt="toggle" title="Toggle mode" /></a>
				</td>
			</tr>
			<tr>
				<td style="width: 8em; padding: 0;">Waiting for input:</td>
				<td style="width: 4.5em; padding: 0;" id="needinput_indicator">N/A</td>
				<td style="padding: 0;" id="needinput_buttons">
					<a href="javascript:window.continue()" style="display:none" id="continue_button"><img src="/images/play.png" alt="continue" title="Continue" /></a>
					<a href="/croplive/<?= $testname ?>" style="display:none" id="crop_button"><img src="/images/edit.png" alt="crop" title="Crop Image" /></a>
					<a href="javascript:window.stopWaitforneedle()" style="display:none" id="stop_waitforneedle_button"><img src="/images/cancel.png" alt="cancel" title="Stop waitforneedle" /></a>
				</td>
			</tr>
		</table>
	</div>
	<div class="grid_5 box box-shadow alpha" id="modules_box" style="min-height: 508px;">
		<div class="box-header aligncenter">Test modules</div>
		<div id="modlist_content"></div>
	</div>
</div>

<div class="grid_14 alpha">
	<div class="grid_14 box box-shadow omega">
		<div style="margin: 0 10px;">
			<div style="width: 800px; height: 600px; background-color: #202020;">
				<? if($running) { ?>
				<img src="/mjpeg/<?= $testname ?>" alt="Waiting for new Images..." style="width: 800px; height: 600px;" />
				<? } else { ?>
				<font color="red"><b>Error:</b> Test not running!</font>
				<? } ?>
			</div>
		</div>
	</div>

	<div class="grid_14 box box-shadow omega" onmouseover="window.scrolldownc = 0;" onmouseout="window.scrolldownc = 1;">
		<div class="box-header aligncenter">Live Log</div>
		<div style="margin: 0 10px;">
			<iframe id="livelog" src="about:blank" style="width: 98.9%; height: 20em; overflow-x: hidden;"><? if($running) { ?><a href="<?= path_to_url($basepath) ?>autoinst-log.txt">Test Log</a><? } else { ?>Test not running!<? } ?></iframe>
		</div>
		<script type="text/javascript">
			<? if($running) { ?>
			init_running("<?= $testname ?>");
			<? } ?>
		</script>
	</div>
	<? if($backend_info) { ?>
	<? $backend_info->{'backend'} =~s/^.*:://; ?>
	<div class="grid_4 box box-shadow omega">
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
? } # endblock content
