window.onload = function (e) {
    'use strict';
    var video = document.getElementById('video');
    video.textTracks[0].mode = 'showing';

    // Obtain handles to buttons and other elements
    var playpause = document.getElementById('playpause');
    var prev = document.getElementById('prev');
    var next = document.getElementById('next');
    var progress = document.getElementById('progress');
    var progressBar = document.getElementById('progress-bar');
    var subtitles = document.getElementById('subtitles');
    var slow = document.getElementById('slow');
    var fast = document.getElementById('fast');
    var fpsdisplay = document.getElementById('fps');

    video.addEventListener('loadedmetadata', function() {
        progress.setAttribute('max', video.duration);
    });

    // As the video is playing, update the progress bar
    video.addEventListener('timeupdate', function() {
        // For mobile browsers, ensure that the progress element's max attribute is set
        if (!progress.getAttribute('max')) progress.setAttribute('max', video.duration);
        progress.value = video.currentTime;
        progressBar.style.width = Math.floor((video.currentTime / video.duration) * 100) + '%';
    });

    // React to the user clicking within the progress bar
    progress.addEventListener('click', function(e) {
        // Also need to take the parents into account here as .controls and figure now have position:relative
        var pos = (e.pageX  - (this.offsetLeft + this.offsetParent.offsetLeft + this.offsetParent.offsetParent.offsetLeft)) / this.offsetWidth;
        video.currentTime = pos * video.duration;
    });

    playpause.addEventListener('click', function(e) {
        if (video.paused || video.ended) video.play();
        else video.pause();
    });

    // Add event listeners for video specific events
    video.addEventListener('play', function() {
        playpause.firstChild.setAttribute('class', 'fa fa-pause');
    }, false);

    video.addEventListener('pause', function() {
        playpause.firstChild.setAttribute('class', 'fa fa-play');
    }, false);

    prev.addEventListener('click', function(e) {
        if (video.paused) video.currentTime -= 0.04;
    });

    next.addEventListener('click', function(e) {
        if (video.paused) video.currentTime += 0.04;
    });

    slow.addEventListener('click', function(e) {
        frameRateDec();
    });

    fast.addEventListener('click', function(e) {
        frameRateInc();
    });

    function toggleTime() {
        if (video.textTracks[0].mode == 'showing') {
            video.textTracks[0].mode = 'hidden';
        } else {
            video.textTracks[0].mode = 'showing';
            // Workaround for FF, otherwise its only shown on the next frame
            if (video.paused) video.currentTime += 0;
        }
    }

    subtitles.addEventListener('click', function(e) {
        toggleTime();
    });

    var playbackRates = [ 1.0/12, 1.0/4, 0.5, 1, 2 ];

    function frameRateInc() {
        if (video.playbackRate >= 2.0) return;
        var i;
        for (i = 0; i < playbackRates.length - 1; i++) {
            if (playbackRates[i] >= video.playbackRate)
                break;
        }
        video.playbackRate = playbackRates[i + 1];
        var fps = video.playbackRate * 24;
        fpsdisplay.setAttribute('data-fps', fps);
    }

    function frameRateDec() {
        if (video.playbackRate <= 1.0/12) return;
        var i;
        for (i = 1; i < playbackRates.length; i++) {
            if (playbackRates[i] >= video.playbackRate)
                break;
        }
        video.playbackRate = playbackRates[i - 1];
        var fps = video.playbackRate * 24;
        fpsdisplay.setAttribute('data-fps', fps);
    }


    // Key bindings
    document.onkeydown = function(e) {
        switch(e.which) {
            case 32: // space
                if (video.paused || video.ended) video.play();
                else video.pause();
                break;

            case 37: // left
                if (video.paused) video.currentTime -= 0.04;
                break;

            case 39: // right
                if (video.paused) video.currentTime += 0.04;
                break;

            case 38: // up
                frameRateInc();
                break;

            case 40: // down
                frameRateDec();
                break;

            case 84: // 't'
                toggleTime();
                break;

            default:
                // alert(e.which);
                return; // exit this handler for other keys
        }
        e.preventDefault(); // prevent the default action (scroll / move caret)
    };
};
