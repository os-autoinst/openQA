? extends 'fluid'

? block locbar => sub {
?= super()
&gt; <a href="/results/">Results</a>
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
		<form method="get" action="" class="cutofftimeform" id="filterform">
			<input type="hidden" name="sort" value="<?= $options->{'sort'} ?>" />
			<select name="hours">
				<? for my $hv (24,96,200,300) { ?>
				<option value="<?= $hv ?>"<?= encoded_string(($hv == $options->{'hours'})?' selected="selected"':'') ?>><?= $hv ?> h</option>
				<? } ?>
			</select>
			<input type="text" name="match"<? if(defined $options->{'match'}) { ?> value="<?= $options->{'match'} ?>"<? } ?> />
			filter
			<label><input type="checkbox" name="ib" value="on"<? if($options->{'ib'}) { ?> checked="checked"<? } ?> />ignore boring results</label>
			<select name="ob" onchange="document.getElementById('filterform').submit();">
				<option value="">All Backends</option>
				<option<?= (defined $options->{'ob'} and $options->{'ob'} eq 'kvm2usb')?' selected="selected':'' ?>>kvm2usb</option>
				<option<?= (defined $options->{'ob'} and $options->{'ob'} eq 'qemu')?' selected="selected':'' ?>>qemu</option>
				<option<?= (defined $options->{'ob'} and $options->{'ob'} eq 'vbox')?' selected="selected':'' ?>>vbox</option>
			</select>
			<input type="submit" value="change" class="smbutton" />
		</form>
	<p />
	<table style="width: 95%;">
		<tr>
			<th>link</th>
			<th>backend<?= sortarrows('backend') ?></th>
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
				<a href="/<?= $prj ?>/testresults/<?= $test->{'testname'} ?>/video.ogv"><img width="23" height="23" src="/images/video.png" alt="ogv" title="ogg/theora video of this testrun"/></a>
				<a href="/schedule/<?= $test->{'testname'} ?>?redirect_back=results"><img src="/images/toggle.png" alt="restart" title="Restart Job"/></a>
				<? } ?>
			</td>
			<td><?= $test->{'backend'} ?></td>
			<td><?= $test->{'distri'} ?></td>
			<td><?= $test->{'type'} ?></td>
			<td><?= $test->{'arch'} ?></td>
                        <?= my $resultclass = ($test->{'running'} || ($test->{'res_overall'}||'') eq "ok")?'':'overviewfail' ?>
                        <?= $resultclass = 'overviewunknown' if ($resultclass eq '' && $test->{'res_dents'}) ?>
			<td><span class="textlink <?= $resultclass ?>"><a href="/buildview/<?= $test->{'distri'} ?>/Build<?= $test->{'build'} ?>"><?= $test->{'build'} ?></a></span></td>
			<td><span class="<?= $resultclass ?>"><?= $test->{'extrainfo'} ?></span></td>
			<td><?= AWisodatetime2($test->{'mtime'}) ?></td>
			<? if($test->{'running'}) { ?>
? #<td colspan="3"><?= $test->{'run_stat'}->{'moddone'} ?> / <?= $test->{'run_stat'}->{'modcount'} ?></td>
				<td colspan="3" style="padding: 3px 4px;">
					<div class="pbox">
						<? my $ptext = ""; ?>
						<? if($test->{'run_stat'}->{'modcount'} > 0) { ?>
						<? $ptext = int($test->{'run_stat'}->{'moddone'} / $test->{'run_stat'}->{'modcount'} * 100)."%"; ?>
							<? if(!$test->{'run_stat'}->{'run_backend'}) { ?>
							<? $ptext = "post-processing"; ?>
							<? } ?>
						<? } else { ?>
						<? $ptext = "pre-processing"; ?>
						<? } ?>
						<progress style="width: 100%; height: 100%;" max="<?= $test->{'run_stat'}->{'modcount'} ?>" <?= encoded_string(($test->{'run_stat'}->{'run_backend'} and $test->{'run_stat'}->{'modcount'} > 0)?"value='".$test->{'run_stat'}->{'moddone'}."'":"") ?>>
							<?= $ptext ?>
						</progress>
						<?= $ptext ?>
					</div>
				</td>
			<? } else { ?>
			<td><span class="overviewok"><?= ($test->{'res_ok'})?$test->{'res_ok'}:'' ?></span></td>
			<td><span class="overviewunknown"><?= encoded_string(($test->{'res_unknown'})?'&nbsp;'.$test->{'res_unknown'}.'&nbsp;':'') ?></span></td>
			<td><span class="overviewfail"><?= encoded_string(($test->{'res_fail'})?'&nbsp;'.$test->{'res_fail'}.'&nbsp;':'') ?></span></td>
			<? } ?>
		</tr>
		<? } ?>
		<? for my $test (@$schedulelist) { ?>
		<tr class="<?= cycle() ?>">
			<td style="font-style: italic;">scheduled</td>
			<td>n/a</td>
			<td><?= $test->{'distri'} ?></td>
			<td><?= $test->{'type'} ?></td>
			<td><?= $test->{'arch'} ?></td>
			<td><span class="textlink"><a href="/buildview/<?= $test->{'distri'} ?>/Build<?= $test->{'build'} ?>"><?= $test->{'build'} ?></a></span></td>
			<td><span class=""><?= $test->{'extrainfo'} ?></span></td>
			<td colspan="4" style="padding: 3px 4px; font-style: italic;">
				<a href="/schedule/<?= $test->{'testname'} ?>?cancel=1" onclick="this.href += '&redirect_back=1'" rel="nofollow">cancel</a>
			</td>
		</tr>
		<? } ?>
	</table>
	<p>Note: times are UTC</p>
</div>
? } # endblock content
