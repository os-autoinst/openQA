? extends 'fluid'

? block locbar => sub {
<?= $self->include_file("../../htdocs/includes/moduleslistlocbar") ?>
? }

? block content => sub {
<div class="grid_3 alpha" id="sidebar">
	<div class="box box-shadow alpha" id="actions_box">
		<div class="box-header aligncenter">Actions</div>
		<div class="aligncenter">
			<?= $self->include_file("../../htdocs/includes/moduleslistoptions") ?>
			<? if(is_authorized_rw()) { ?>
			<a href="/cropimg/edit/<?= $testname ?>/<?= $testmodule ?>/<?= $testindex ?>"><img src="/images/edit.png" alt="crop" title="Crop Image" /></a>
			<? } ?>
		</div>
	</div>

	<?= $self->include_file("../../htdocs/includes/moduleslist") ?>
</div>

<div class="grid_13 omega">
	<?= $self->include_file("../../htdocs/includes/moduleslistthumbnails") ?>

	<div class="box box-shadow">
		<?= $self->include_file("../../htdocs/includes/moduleslisttabs") ?>
		<div style="margin: 0 10px; position: relative; width: 800px; height: 600px;">
			<a href="/<?= $prj ?>/testresults/<?= $testname ?>/<?= $imgname ?>">
				<img src="/<?= $prj ?>/testresults/<?= $testname ?>/<?= $imgname ?>?fixsize=1" width="800" height="600"
				alt="<?= $imgname ?>" style="position: absolute; z-index: 2;" />
				<? if (1) { ?>
				<script type="text/javascript">
                                        var areas = <?= $areas ?>;
					var scr_x = <?= $img_width ?>;
					var scr_y = <?= $img_height ?>;
                                        var imgpath ="/<?= $prj ?>/testresults/<?= $testname ?>/";

                                        var colorset = {
                                            'ok':   { 'stroke': 'rgb(34,255,8)', 'fill': 'rgba(151, 208, 5, .5)'},
                                            'fail': { 'stroke': 'rgb(255,0,0)', 'fill': 'rgba(255, 77, 77, .5)'},
                                        };

					document.write('<canvas id="cmatch" class="cmatch" width="800" height="600" style="position: absolute; z-index: 3;"></canvas>');
					var canvas = document.getElementById('cmatch');
					var context = canvas.getContext('2d');

                                        for(var i in areas) {
                                            var area = areas[i];
 	 				    if(scr_x > 800 || scr_y > 600) {
  						area['x'] = (area['x'] / scr_x) * 800;
						area['y'] = (area['y'] / scr_y) * 600;
						area['w'] = (area['w'] / scr_x) * 800;
						area['h'] = (area['h'] / scr_y) * 600;
					    }

                                            context.font = "bold 12px sans-serif";
                                            context.fillStyle = colorset[area['result']]['stroke'];
                                            var text = String(area['similarity']) + "%";
                                            var text_width = context.measureText(text).width;
                                            var text_xpos = area['x']+area['w']-text_width-2;
                                            var text_ypos = area['y']+area['h']-3;
                                            context.fillText(text, text_xpos, text_ypos);
    
        				    context.lineWidth = 3;
    					    context.strokeStyle = colorset[area['result']]['stroke'];
    					    context.strokeRect(area['x'], area['y'], area['w'], area['h']);
                                            if(area['diff']) { 
                                                context.globalCompositeOperation='destination-over';
                                                var imageObj = new Image();
                                                imageObj.onload = function() {
                                                    context.drawImage(imageObj, area['x'], area['y'], area['w'], area['h']);
                                                };
                                                imageObj.src = imgpath + area['diff'];
                                            }
                                            else {
                                                context.fillStyle = colorset[area['result']]['fill'];
    					        context.fillRect(area['x'], area['y'], area['w'], area['h']);
                                            }
                                        }
				</script>
				<? } ?>
			</a>
		</div>
	</div>

</div>
? } # endblock content
