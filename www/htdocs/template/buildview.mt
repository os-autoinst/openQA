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
					<th colspan="2"><?= $type ?></th>
				<? } ?>
			</tr>
			<tr>
				<th>Test</th>
				<? for my $type (@$types) { ?>
					<? for my $arch (@{$$archs{$type}}) { ?>
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
								<span class="overview<?= $res->{overall} ?>">
									<?= $res->{ok} ?> /
									<?= $res->{unknown} ?> /
									<?= $res->{fail} ?>
								</span>
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
