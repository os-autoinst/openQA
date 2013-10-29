? extends 'fluid'

? block additional_headlines => sub {
	<script src="/static/table.js" type="text/javascript"></script>
? }

? block locbar => sub {
?= super()
&gt; <a href="/results/">Results</a>
? }

? block content => sub {
<div class="grid_16 box box-shadow omega">
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
	<table style="width: 95%;" id="results" class="table-autosort table-autofilter table-autostripe table-stripeclass:odd">
		<thead>
		<tr>
			<th class="table-sortable:alphanumeric">link</th>
			<th class="table-sortable:alphanumeric table-filterable">backend</th>
			<th class="table-sortable:alphanumeric table-filterable">distri</th>
			<th class="table-sortable:alphanumeric table-filterable">type</th>
			<th class="table-sortable:alphanumeric table-filterable">arch</th>
			<th class="table-sortable:alphanumeric table-filterable">build</th>
			<th class="table-sortable:alphanumeric table-filterable">extra</th>
			<th class="table-sortable:date">testtime</th>
			<th class="table-sortable:numeric">OK</th>
			<th class="table-sortable:numeric">unk</th>
			<th class="table-sortable:numeric">fail</th>
		</tr>
		</thead>
		<tbody>
		<? for my $test (@$resultlist) { ?>
		<tr>
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
                        <!-- <?= my $resultclass = '';
                        $resultclass = 'overviewfail' if (!$test->{'running'} && ($test->{'res_overall'}||'') ne 'ok');
                        $resultclass = 'overviewunknown' if (($test->{'res_overall'}||'') eq 'ok' && $test->{'res_dents'}); ?>
                        -->
			<td><span class="textlink <?= $resultclass ?>"><a href="/buildview/<?= $test->{'build'} ?>"><?= $test->{'build'} ?></a></span></td>
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
		<tr>
			<td style="font-style: italic;">scheduled</td>
			<td><?= $test->{'priority'} ?></td>
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
		</tbody>
	</table>
	<p>Note: times are UTC</p>
</div>
? } # endblock content
