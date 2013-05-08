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
<?= $self->include_file("../../htdocs/includes/moduleslistlocbar") ?>
? }

? block content => sub {
<div class="grid_3 alpha">
	<div class="box box-shadow alpha" id="actions_box">
		<div class="box-header aligncenter">Actions</div>
		<div class="aligncenter">
			<?= $self->include_file("../../htdocs/includes/moduleslistoptions") ?>
			<a href='/viewsrc/raw/<?= $testname ?>/<?= $testmodule ?>'><img src='/images/log.png' alt='raw test' title='raw test' height='23' width='23' /></a>
		</div>
	</div>
	
	<?= $self->include_file("../../htdocs/includes/moduleslist") ?>
</div>

<div class="grid_13 omega">
	<div class="box box-shadow">
		<?= $self->include_file("../../htdocs/includes/moduleslisttabs") ?>
		<p>
			Test-Module: <tt><?= $scriptpath ?></tt>
		</p>
		<?= encoded_string syntax_highlight($scriptsrc) ?>
	</div>
</div>
? } # endblock content
