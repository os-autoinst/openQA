? extends 'fluid'

? block additional_headlines => sub {
<script src="/static/shapes.js" type="text/javascript"></script>
<script src="/static/needleeditor.js" type="text/javascript"></script>
<script src="/static/prototype.js" type="text/javascript"></script>
<script src="/static/openqa.js" type="text/javascript"></script>
<script src="/static/cropimg.js" type="text/javascript"></script>
<script src="/static/keyevent.js" type="text/javascript"></script>
<script type="text/javascript">
<!--
// Prototype introduces undesired toJSON definition
delete Array.prototype.toJSON;

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
			<div style="margin: 0 3px;">
				<div style="margin-top: 1em;">
				<label>Name:</label><br/>
				<input type="input" name="needlename" id="needleeditor_name" value="<?= $needlename ?>" style="width: calc(100% - 8px);"/>
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
					<input id="newtag" style="width: calc(100% - 6px - 40px);" onkeypress="if (event.keyCode==13) { return window.addTag(); }"/> <input type="button" onclick="return window.addTag();" style="width: 34px;" class="button" value="Add" />
				</div>
				<div style="margin-top: 1em;">
					<label>JSON:</label><br/>
					<textarea id="needleeditor_textarea" name="json" readOnly="yes" style="width: calc(100% - 8px); height:300px;"></textarea>
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

		<? if ($error_msg) { ?>
			<blockquote class="ui-state-error" style="margin-bottom: 0.6em;"><?= $error_msg ?></blockquote>
		<? } ?>
		<? if ($info_msg) { ?>
			<blockquote class="ui-state-highlight" style="margin-bottom: 0.6em;"><?= $info_msg ?></blockquote>
		<? } ?>

		<table style="width: 97%;">
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
					<td><input type="radio" name="background_selector" data-path="<?= $needle->{'imagepath'} ?>" data-url="<?= $needle->{'imageurl'} ?>" onclick="window.loadBackground(this);" <?= 'checked="checked"' if ($i == 0); ?> /></td>
					<td><input type="radio" name="area_selector" onclick="window.nEditor.LoadAreas('<?= JSON::to_json($needle->{'area'}) ?>');"/></td>
					<td><input type="radio" name="area_selector" onclick="window.nEditor.LoadAreas('<?= JSON::to_json($needle->{'matches'}) ?>');" <?= 'checked="checked"' if ($i == 1); ?>/></td>
					<td><input type="radio" name="tags_selector" data-tags="<?= JSON::to_json($needle->{'tags'}) ?>" onclick="window.loadTags(this);" <?= 'checked="checked"' if ($i == 1 || scalar(@$needles) == 1); ?>/></td>
				</tr>
			<? } ?>
		</table>
		<div style="margin: 0 10px; position: relative; width: 1024px; height: 768px;">
             		<canvas tabindex="1" id="needleeditor_canvas" width="1024" height="768" style="border: 1px solid black;">This text is displayed if your browser does not support HTML5 Canvas.</canvas>
		</div>
	</div>
</div>
? } # endblock content
