? extends 'fluid'

? block locbar => sub {
?= super()
&gt; <a href="/results/">Results</a>
&gt; <?= $build ?>
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
								<? my $state = $res->{state}; ?>
								<? if ($state eq "done") { ?>
									<span class="overview<?= $res->{overall} ?>">
									<a href="/results/<?= $res->{testname} ?>"><?= $res->{ok} ?>/<?= $res->{unknown} ?>/<?= $res->{fail} ?></a>
									</span>
								<? } elsif ($state eq "running") { ?>
									<span><a href="/running/<?= $res->{testname} ?>">running</a></span>
								<? } else { ?>
									<span><?= $state ?></span>
								<? } ?>
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
