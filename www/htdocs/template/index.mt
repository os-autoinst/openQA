? extends 'defstyle'

? block locbar => sub {
?= super()
? }

? block content => sub {
<div class="grid_6 box box-shadow alpha recent-issues-hide" id="top_features_box">
	<div class="box-header aligncenter">
		Recent issues in Factory
	</div>
	<?= $self->include_file("../includes/knownissues") ?>
</div>

<div class="grid_10 box box-shadow omega">
	<h1>Welcome to <?= $app_title ?></h1>
	<p>
		<a href="/results/"><img src="/images/factory-tested.png" alt="factory-tested logo" class="tactorytestedlogo"/></a>
		This machine runs regular automated tests of the openSUSE Factory distribution to find bugs early in the development cycle. <br/>
		Read more on 
		<a href="http://en.opensuse.org/openSUSE:OpenQA">What</a>,
		<a href="http://en.opensuse.org/openSUSE:Factory-tested_Proposal">Why</a>
		and <a href="http://lwn.net/Articles/414413/">How</a>.
	</p>
	<ul>
		<li><b><a href="/results/">test result overview</a></b></li>
		<li><a href="/opensuse/video/">all result videos and log files are in here</a></li>
	</ul>
	<h3>Testing Software</h3>
	<p>
		If you want to setup a similar automated testing system, you can use the <a href="http://www.os-autoinst.org/">OS autoinst</a> software.
	</p>
	<h3>Contact</h3>
	<p>
		This service is maintained by Bernhard M. Wiedemann &lt;bernhard+openqa &auml;t lsmod de&gt;
	</p>
</div>
? } # endblock content

? block footer => sub {
	 <a title="SUSE" href="http://en.opensuse.org/Sponsors"><img alt="SUSE" src="/images/suse.png" title="SUSE" height="58" width="99" /></a>
&nbsp;
	  <a title="B1 Systems" href="http://www.b1-systems.de/">
	    <img alt="B1-systems" src="/images/b1-systems.png" height="60" width="60" /></a>
	  <br/>
	  <br/>
? }
