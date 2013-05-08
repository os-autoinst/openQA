<? if($modinfo->{'running'} eq "") { ?>
	<a href="/results/<?= $testname ?>"><img src="/images/back.png" alt="back to result details" title="back to result details" height="22" width="23" /></a>
<? } else { ?>
	<a href="/running/<?= $testname ?>"><img src="/images/back.png" alt="back to running test" title="back to running test" height="22" width="23" /></a>
<? } ?>
