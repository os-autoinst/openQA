<div class="box box-shadow alpha" id="testmodules_box">
	<div class="box-header aligncenter">Test modules</div>
	<div id="modcontent">
	<? foreach my $category (@{$modinfo->{'modlist'}}) { ?>
		<h2 class="box-subheader modcategory"><?= $category->{'category'} ?></h2>
		<ul class="navigation modcategory">
			<? foreach my $module (@{$category->{'modules'}}) { ?>
				<?
				my @classes = ();
				push(@classes, "mod-".$module->{'state'});
				push(@classes, "result".$module->{'result'});
				push(@classes, "selected") if ($module->{'name'} eq $testmodule);
				?>
				<li class="<?= join(" ", @classes) ?>">
					<a href="/viewimg/show/<?= $testname ?>/<?= $module->{'name'} ?>/1"><?= $module->{'name'} ?></a>
				</li>
			<? } ?>
		</ul>
	<? } ?>
	</div>
</div>
