<div class="box box-shadow alpha" id="testmodules_box">
	<div class="box-header aligncenter">Test modules</div>
	<div id="modlist_content"></div>
	<script type="text/javascript">
		window.updateModuleslist(JSON.parse('<?= encoded_string(JSON::to_json($modinfo->{'modlist'})) ?>'), "<?= $testname ?>", "<?= $testmodule ?>");
	</script>
</div>
