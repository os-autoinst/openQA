? extends 'defstyle-18'

? block additional_headlines => sub {
<script src="/static/prototype.js" type="text/javascript"></script>
<script src="/static/running.js" type="text/javascript"></script>
<style type="text/css">
<!--
td {
	padding: 0 0 0 0.5em;
	text-align: left;
	border: none;
	vertical-align: middle;
}
td a {
	color: #004f78 !important;
}
table {
	border: none;
	margin: 0;
	font-family: "monospace", monospace;
	font-size: 10.5667px;
	line-height: 13px;
}
-->
</style>
? }

? block locbar => sub {
?= super()
&gt; Running Tests
&gt; <?= $testname ?>
? }

? block content => sub {
<div class="grid_5 alpha">
	<div class="grid_5 box box-shadow alpha" id="actions_box">
		<div class="box-header aligncenter">Actions</div>
		<div class="aligncenter">
			<? if(is_authorized_rw()) { ?>
			<a href="/croplive/<?= $testname ?>?getlastimg=1"><img src="/images/edit.png" alt="crop" title="Crop Image" /></a>
			<a href="javascript:stopcont()" class="pauseplay pause" id="stopcont" title="pause testrun"></a>
			<? } ?>
			<a href="/results/"><img src="/images/back.png" alt="back" title="back to result page" /></a> 
		</div>
	</div>
	<div class="grid_5 box box-shadow alpha" id="modules_box" style="min-height: 508px;">
		<div class="box-header aligncenter">Modules</div>
		<div id="modcontent">
		</div>
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
			<iframe id="livelog" src="about:blank" style="width: 98.9%; height: 20em; overflow-x: hidden;"><? if($running) { ?><a href="<?= path_to_url($basepath) ?>currentautoinst-log.txt">Test Log</a><? } else { ?>Test not running!<? } ?></iframe>
		</div>
		<script type="text/javascript">
			<? if($running) { ?>
			init_running("<?= $testname ?>");
			<? } ?>
		</script>
	</div>
</div>
? } # endblock content
