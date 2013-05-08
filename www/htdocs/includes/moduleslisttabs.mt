<div class="box-header header-tabs">
	<ul>
		<li <?= ($action eq 'viewimg') ? 'class=selected' : '' ?>>
			<a href="/viewimg/<?= $prj ?>/testresult/<?= $testname ?>/<?= $testmodule ?>/1">Screenshots</a>
		</li>
		<li <?= ($action eq 'viewsrc') ? 'class=selected' : '' ?>>
			<a href="/viewsrc/show/<?= $testname ?>/<?= $testmodule ?>">Source code</a>
		</li>
	</ul>
</div>
