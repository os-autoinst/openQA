<div class="box-header header-tabs">
	<ul>
		<li <?= ($action eq 'viewimg') ? 'class=selected' : '' ?>>
			<a href="/viewimg/show/<?= $testname ?>/<?= $testmodule ?>/<?= $testindex ?>">Screenshot</a>
		</li>
		<li <?= ($action eq 'cropimg') ? 'class=selected' : '' ?>>
			<a href="/cropimg/show/<?= $testname ?>/<?= $testmodule ?>/<?= $testindex ?>">Needles editor</a>
		</li>
		<li <?= ($action eq 'viewsrc') ? 'class=selected' : '' ?>>
			<a href="/viewsrc/show/<?= $testname ?>/<?= $testmodule ?>/<?= $testindex ?>">Source code</a>
		</li>
	</ul>
</div>
