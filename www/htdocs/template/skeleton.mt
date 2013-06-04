?= encoded_string '<?xml version="1.0" encoding="UTF-8"?>'
<!DOCTYPE html
	PUBLIC "-//W3C//DTD XHTML 1.0 Transitional//EN"
	"http://www.w3.org/TR/xhtml1/DTD/xhtml1-transitional.dtd">
<html xmlns="http://www.w3.org/1999/xhtml" lang="en-US" xml:lang="en-US">
<head>
	<? block head => sub { ?>
	<title><? block title => sub { ?><?= $app_title ?><? } ?></title>
	<meta http-equiv="Content-Type" content="text/html; charset=utf-8" />
	<link href="/favicon.ico" rel="shortcut icon" />
	<? block csstype => sub { ?>
	<link href="http://static.opensuse.org/themes/bento/css/style.css" media="screen" rel="stylesheet" title="Normal" type="text/css" />
	<? } ?>
	<link href="/static/openqa.css" media="screen" rel="stylesheet" type="text/css" />
	<? block additional_headlines => sub { } ?>
	<? } ?><?# endblock head ?>
</head>
<body>
	<div id="header">
		<div id="header-content" class="container_<? block headsize => sub { ?>16<? } ?>">
			<a id="header-logo" href="http://www.opensuse.org"><img src="/images/header-logo.png" alt="Header Logo" height="26" width="46"/></a>
			<ul id="global-navigation">
				<li id="item-downloads"><a href="http://software.opensuse.org/">Downloads</a></li>
			</ul>
		</div>
	</div>

	<div id="subheader" class="container_<? block subheadsize => sub { ?>16<? } ?>">
		<div id="breadcrump" class="grid_16 alpha">
			<? block locbar => sub { ?>
			<a href="/"><img alt="Home" src="/images/home_grey.png" /> <b><?= $app_title ?></b> - <?= $app_subtitle ?></a>
			<? } ?>
		</div>
	</div>

	<div id="content" class="container_<? block contentsize => sub { ?>16<? } ?> content-wrapper">
		<? block content => sub { } ?>
	</div>

	<div class="clear"></div>
	<div id="footer" class="container_16">
		<div class="box_content grid_16" style="text-align: center;">
			<? block footer => sub {} ?>
			<!--
			<a href="http://validator.w3.org/check?uri=referer"><img src="http://www.w3.org/Icons/valid-xhtml10" alt="Valid XHTML 1.0 Transitional" height="31" width="88" /></a>
			-->
		</div>
	</div>
</body>
</html>
