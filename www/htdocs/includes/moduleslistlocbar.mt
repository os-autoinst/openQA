?= super()
<? if($modinfo->{'running'} eq "") { ?>
	&gt; <a href="/results/<?= $testname ?>"><?= $testname ?></a>
<? } else { ?>
	&gt; <a href="/running/<?= $testname ?>"><?= $testname ?></a>
<? } ?>
&gt; <?= $testmodule ?>

