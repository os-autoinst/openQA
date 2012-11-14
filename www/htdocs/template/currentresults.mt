? extends 'fluid'

? block locbar => sub {
?= super()
&gt; Results
? }

? block content => sub {
<div class="grid_5 box box-shadow alpha recent-issues-hide" id="top_features_box">
	<div class="box-header aligncenter">
		Recent issues in Factory
	</div>
	<?= $self->include_file("../../htdocs/includes/knownissues") ?>
</div>
<div class="grid_11 box box-shadow omega">
	<h2>Test result overview</h2>
	<p>This page lists <?= @$resultlist ?> automated test-results from the last <?= $hoursfresh ?> hours.</p>
		<form method="get" action="" class="cutofftimeform">
			<input type="hidden" name="sort" value="<?= $options->{'sort'} ?>" />
			<select name="hours">
				<? for my $hv (24,96,200,300) { ?>
				<option value="<?= $hv ?>"<?= encoded_string(($hv == $options->{'hours'})?' selected="selected"':'') ?>><?= $hv ?> h</option>
				<? } ?>
			</select>
			<input type="text" name="match"<? if(defined $options->{'match'}) { ?> value="<?= $options->{'match'} ?>"<? } ?> />
			filter
			<label><input type="checkbox" name="ib" value="on"<? if($options->{'ib'}) { ?> checked="checked"<? } ?> />ignore boring results</label>
			<input type="submit" value="change" class="smbutton" />
		</form>
	<p />
	<table style="width: 95%;">
		<tr>
			<th>link</th>
			<th>distri<?= sortarrows('distri') ?></th>
			<th>type<?= sortarrows('type') ?></th>
			<th>arch<?= sortarrows('arch') ?></th>
			<th>build<?= sortarrows('build') ?></th>
			<th>extra<?= sortarrows('extrainfo') ?></th>
			<th>testtime<?= sortarrows('mtime') ?></th>
			<th>OK<?= sortarrows('res_ok') ?></th>
			<th>unk<?= sortarrows('res_unknown') ?></th>
			<th>fail<?= sortarrows('res_fail') ?></th>
		</tr>
		<? cycle(1) ?>
		<? for my $test (@$resultlist) { ?>
		<tr class="<?= cycle() ?>">
			<td>
				<? if($test->{'running'}) { ?>
				<a href="/running/<?= $test->{'testname'} ?>">testing</a>
				<? } else { ?>
				<a href="/results/<?= $test->{'testname'} ?>"><img src="/images/details.png" alt="details" title="test result details" height="23" width="23" /></a>
				<a href="/<?= $prj ?>/video/<?= $test->{'testname'} ?>.ogv"><img width="23" height="23" src="/images/video.png" alt="ogv" title="ogg/theora video of this testrun"/></a>
				<? } ?>
			</td>
			<td><?= $test->{'distri'} ?></td>
			<td><?= $test->{'type'} ?></td>
			<td><?= $test->{'arch'} ?></td>
			<td><span class="textlink <?= (!defined $test->{'res_overall'} || $test->{'res_overall'} eq "OK")?'':'overviewfail' ?>"><a href="/buildview/Build<?= $test->{'build'} ?>"><?= $test->{'build'} ?></a></span></td>
			<td><span class="<?= (!defined $test->{'res_overall'} || $test->{'res_overall'} eq "OK")?'':'overviewfail' ?>"><?= $test->{'extrainfo'} ?></span></td>
			<td><?= AWisodatetime2($test->{'mtime'}) ?></td>
			<td><span class="overviewok"><?= ($test->{'res_ok'})?$test->{'res_ok'}:'' ?></span></td>
			<td><span class="overviewunknown"><?= encoded_string(($test->{'res_unknown'})?'&nbsp;'.$test->{'res_unknown'}.'&nbsp;':'') ?></span></td>
			<td><span class="overviewfail"><?= encoded_string(($test->{'res_fail'})?'&nbsp;'.$test->{'res_fail'}.'&nbsp;':'') ?></span></td>
		</tr>
		<? } ?>
	</table>
	<p>Note: times are UTC</p>
</div>
? } # endblock content
