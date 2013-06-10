? extends 'fluid'

? block additional_headlines => sub {
<script src="/static/prototype.js" type="text/javascript"></script>
<script src="/static/openqa.js" type="text/javascript"></script>
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
		</div>
	</div>

	<?= $self->include_file("../../htdocs/includes/moduleslist") ?>
</div>

<div class="grid_13 omega">
	<?= $self->include_file("../../htdocs/includes/moduleslistthumbnails") ?>

	<div class="box box-shadow">
		<?= $self->include_file("../../htdocs/includes/moduleslisttabs") ?>

		<div style="margin: 6px;">
			<table style="width: 300px;">
				<tr>
					<td>Expected DTMF</td>
					<td><tt><?= $audio_details->{'reference_text'} ?></tt></td>
				</tr>
				<tr>
					<td>Decoded DTMF</td>
					<td><tt><?= $audio_details->{'decoded_text'} ?></tt></td>
				</tr>
			</table>
			<br />
			<audio style="width: 300px; margin: 0 10px;" src="<?= $audio ?>" controls="controls"></audio>
		</div>
	</div>

</div>
? } # endblock content
