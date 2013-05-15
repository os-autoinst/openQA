? extends 'fluid'

? block additional_headlines => sub {
<script src="/static/keyevent.js"></script>
<script src="/static/shapes.js"></script>
<script src="/static/needleeditor.js"></script>
<script type="text/javascript">
<!--
function loadBackground(tag) {
	window.nEditor.LoadBackground(tag.dataset.url);
	document.getElementById("needleeditor_image").setAttribute("value", tag.dataset.path);
}

function loadTags(html) {
	var tags = JSON.parse(html.dataset.tags);
	var radios = document.getElementsByName('tags');
	for (var i = 0; i < radios.length; i++) {
		// If we need to switch
		if ( (radios[i].checked && tags.indexOf(radios[i].value) == -1) ||
		     (!radios[i].checked && tags.indexOf(radios[i].value) != -1)) {
			radios[i].click();
		}
	}
}

function addTag() {
	var input = document.getElementById('newtag');
	var checkbox = window.nEditor.AddTag(input.value, false);
	input.value = '';
	checkbox.click();
	return false;
}

window.onload=function(){
	window.nEditor = new NeedleEditor('<?= ${@$needles[0]}{'imageurl'} ?>',	'<?= encoded_string(JSON::to_json($default_needle)) ?>');

};

-->
</script>
? }

? block locbar => sub {
<?= $self->include_file("../../htdocs/includes/moduleslistlocbar") ?>
? }

? block content => sub {
<div class="grid_3 alpha" id="sidebar">
	<div class="box box-shadow alpha" id="actions_box">
		<div class="box-header aligncenter">Actions</div>
		<form action="/cropimg/save/<?= $testname ?>/<?= $testmodule?>/<?= $testindex ?>" method="post">
			<div class="aligncenter">
				<?= $self->include_file("../../htdocs/includes/moduleslistoptions") ?>
				<input type="image" src="/images/floppy.png" alt="Save" />
			</div>
			<div>
				<div style="margin-top: 1em;">
				<label>Name:</label><br/>
				<input type="input" name="needlename" value="<?= $needlename ?>"/>
				</div>
				<div style="margin-top: 1em;">
					<label>Tags:</label><br/>
					<div id="needleeditor_tags" style="margin: 0 18px 0 0;">
						<? for my $tag (@$tags) { ?>
							<label>
								<input type="checkbox" name="tags" id="tag_<?= $tag ?>" onclick="window.nEditor.changeTag(this.value, this.checked);" value="<?= $tag ?>"><?= $tag ?>
							</label><br/>
						<? } ?>
					</div>
					<input id="newtag" style="width:70%" onkeypress="if (event.keyCode==13) { return addTag(); }"/> <a href="#" onclick="return addTag();">Add</a>
				</div>
				<div style="margin-top: 1em;">
					<label>JSON:</label><br/>
					<textarea id="needleeditor_textarea" name="json" readOnly="yes" style="width:94%; height:300px;"></textarea>
					<input type="hidden" id="needleeditor_image" name="imagepath" value="<?= ${@$needles[0]}{'imagepath'} ?>"/>
				</div>
			</div>
		</form>
	</div>

	<?= $self->include_file("../../htdocs/includes/moduleslist") ?>
</div>

<div class="grid_13 omega">
	<?= $self->include_file("../../htdocs/includes/moduleslistthumbnails") ?>

	<div class="box box-shadow">
		<?= $self->include_file("../../htdocs/includes/moduleslisttabs") ?>

		<table style="width: auto;">
			<tr>
				<th>Screens./Needle</th>
				<th>Image</th>
				<th>Areas</th>
				<th>Matches</th>
				<th>Tags</th>
			</tr>
			
			<? for (my $i = 0; $i < scalar(@$needles); $i++) { ?>
				<? my $needle = $needles->[$i]; ?>
				<tr>
					<td><?= $needle->{'name'} ?></td>
					<td><input type="radio" name="background_selector" data-path="<?= $needle->{'imagepath'} ?>" data-url="<?= $needle->{'imageurl'} ?>" onclick="loadBackground(this);" <?= 'checked="checked"' if ($i == 0); ?> /></td>
					<td><input type="radio" name="area_selector" onclick="window.nEditor.LoadAreas('<?= JSON::to_json($needle->{'area'}) ?>');"/></td>
					<td><input type="radio" name="area_selector" onclick="window.nEditor.LoadAreas('<?= JSON::to_json($needle->{'matches'}) ?>');" <?= 'checked="checked"' if ($i == 1); ?>/></td>
					<td><input type="radio" name="tags_selector" data-tags="<?= JSON::to_json($needle->{'tags'}) ?>" onclick="loadTags(this);" <?= 'checked="checked"' if ($i == 1); ?>/></td>
				</tr>
			<? } ?>
		</table>
		<div style="margin: 0 10px; position: relative; width: 1024px; height: 768px;">
             		<canvas tabindex="1" id="needleeditor_canvas" width="1024" height="768" style="border: 1px solid black;">This text is displayed if your browser does not support HTML5 Canvas.</canvas>
		</div>
	</div>
</div>
? } # endblock content
