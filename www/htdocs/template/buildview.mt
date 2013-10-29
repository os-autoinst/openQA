? extends 'fluid'

? block locbar => sub {
?= super()
&gt; <a href="/results/">Results</a>
&gt; <?= $build ?>
<script src="/static/wz_tooltip/wz_tooltip.js" type="text/javascript"></script>
? }

? block content => sub {
<div class="grid_16 box box-shadow omega">
	<h2>Test result overview</h2>
	<p>This page lists the results for <b>Build<?= $build ?></b></p>
	<p />
	<table style="width: 95%;">
		<thead>
			<tr>
				<th></th>
				<? for my $type (@$types) { ?>
					<th colspan="<?= scalar(@{$archs->{$type}}) ?>"><?= $type ?></th>
				<? } ?>
			</tr>
			<tr>
				<th>Test</th>
				<? for my $type (@$types) { ?>
					<? for my $arch (@{$archs->{$type}}) { ?>
						<th><?= $arch ?></th>
					<? } ?>
				<? } ?>
			</tr>
		</thead>
		<tbody>
			<? cycle(1) ?>
			<? for my $config (@$configs) { ?>
				<tr class="<?= cycle() ?>">
					<td><?= $config ?></td>
					<? for my $type (@$types) { ?>
						<? for my $arch (@{$archs->{$type}}) { ?>
							<td>
							<? my $res = $results->{$config}{$type}{$arch} ?>
							<? if ($res) { ?>
								<?
								  my $state = $res->{state};
								  my $jobid = $res->{jobid};
								  my $testname = $res->{testname};
								  my $css = "";
								  $css = "overview".$res->{overall} if ($state eq "done");
								?>

								<?# Visible information ?>
								<span class="<?=$css?>" onmouseout="UnTip()" onmouseover="TagToTip('actions_<?=$jobid?>', STICKY, 1, CLICKCLOSE, true)">
								<? if ($state eq "done") { ?>
									<a href="/results/<?=$testname?>"><?= $res->{ok} ?>/<?= $res->{unknown} ?>/<?= $res->{fail} ?></a>
								<? } elsif ($state eq "running") { ?>
									<a href="/running/<?=$testname?>">running</a>
								<? } elsif ($state eq "scheduled") { ?>
									sched.(<?= $res->{priority} ?>)
								<? } else { ?>
									<?= $state ?>
								<? } ?>
								</span>

								<?# Actions ?>
								<span id="actions_<?=$jobid?>" style="display:none"><ul style="margin: 0px;">
								<? my $href = "/schedule/$testname?back=1&action="; ?>
								<? if ($state eq "scheduled") { ?>
									<? my $prio = $res->{'priority'}; ?>
									<li style="margin: 0px;"><a href="<?= $href."setpriority&priority=".($prio+10)?>">Raise priority</a></li>
									<li style="margin: 0px;"><a href="<?= $href."setpriority&priority=".($prio-10)?>">Lower priority</a></li>
								<? } else { ?>
									<li style="margin: 0px;"><a href="<?=$href."restart"?>">Re-schedule</a></li>
								<? } ?>
								<? if ($state eq "scheduled" || $state eq "running") { ?>
									<li style="margin: 0px;"><a href="<?=$href."cancel"?>">Cancel</a></li>
								<? } ?>
								</ul></span>
							<? } ?>
							</td>
						<? } ?>
					<? } ?>
				</tr>
			<? } ?>
		</tbody>
	</table>
</div>
? } # endblock content
