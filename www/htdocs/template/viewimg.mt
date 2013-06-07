? extends 'fluid'

? block additional_headlines => sub {
<script src="/static/prototype.js" type="text/javascript"></script>
<script src="/static/openqa.js" type="text/javascript"></script>
<script src="/static/needlediff.js" type="text/javascript"></script>
<script type="text/javascript">
<? if (scalar(@$needles) > 0) { ?>
<!--
window.onload=function(){
	window.diff = new NeedleDiff('needle_diff', <?= $img_width ?>, <?= $img_height ?>);
	window.diff.setScreenshot('<?= $screenshot ?>');
	var firstDataset = $('needlediff_selector').options[0].dataset;
	window.diff.setNeedle(firstDataset.image, JSON.parse(firstDataset.areas), JSON.parse(firstDataset.matches));

	$('needlediff_selector').onchange = function() {
		var selDataset = this.options[this.selectedIndex].dataset;
		window.diff.setNeedle(selDataset.image, JSON.parse(selDataset.areas), JSON.parse(selDataset.matches));
	};
};
-->
<? } ?>
</script>
? }

? block locbar => sub {
<?= $self->include_file("../../htdocs/includes/moduleslistlocbar") ?>
? }

? block content => sub {
<div class="grid_3 alpha" id="sidebar">
	<div class="box box-shadow alpha" id="actions_box">
		<div class="box-header aligncenter">Actions</div>
		<div class="aligncenter">
			<?= $self->include_file("../../htdocs/includes/moduleslistoptions") ?>
			<? if(is_authorized_rw()) { ?>
			<a href="/cropimg/show/<?= $testname ?>/<?= $testmodule ?>/<?= $testindex ?>"><img src="/images/edit.png" alt="crop" title="Crop Image" /></a>
			<? } ?>
		</div>
	</div>

	<?= $self->include_file("../../htdocs/includes/moduleslist") ?>
</div>

<div class="grid_13 omega">
	<?= $self->include_file("../../htdocs/includes/moduleslistthumbnails") ?>

	<div class="box box-shadow">
		<?= $self->include_file("../../htdocs/includes/moduleslisttabs") ?>

		<div class="aligncenter">
		<? if (scalar(@$needles) > 0) { ?>
				Candidate needle:
				<select id="needlediff_selector">
				<? for (my $i = 0; $i < scalar(@$needles); $i++) { ?>
					<? my $needle = $needles->[$i]; ?>
					<option data-image="<?= $needle->{'image'} ?>"
						data-areas="<?= JSON::to_json($needle->{'areas'}) ?>"
						data-matches="<?= JSON::to_json($needle->{'matches'}) ?>"><?= $needle->{'name'} ?></option>
				<? } ?>
				</select>
			</div>

			<div style="margin: 5px;">
				<div id="needle_diff"></div>
		<? } else { ?>
			<img src="<?= $screenshot ?>" />
		<? } ?>
		</div>
	</div>

</div>
? } # endblock content
