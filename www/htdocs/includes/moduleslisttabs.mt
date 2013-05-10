<div class="box-header header-tabs">
	<ul>
		<li <?= ($action eq 'viewimg') ? 'class=selected' : '' ?>>
			<a href="/viewimg/show/<?= $testname ?>/<?= $testmodule ?>/1">Screenshots</a>
		</li>
		<li <?= ($action eq 'cropimg') ? 'class=selected' : '' ?>>
			<a href="/cropimg/edit/<?= $testname ?>/<?= $testmodule ?>/1">Needles editor</a>
		</li>
		<li <?= ($action eq 'viewsrc') ? 'class=selected' : '' ?>>
			<a href="/viewsrc/show/<?= $testname ?>/<?= $testmodule ?>">Source code</a>
		</li>
	</ul>
</div>
