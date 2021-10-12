use strict;
use warnings;

[
    NeedleDirs => {
        id => 1,
        path => 't/data/openqa/share/tests/opensuse/needles',
        name => 'fixtures'
    },
    Needles => {
        dir_id => 1,
        filename => 'inst-timezone-text.json',
        last_seen_module_id => 10,
        # keep the timestamps aligned with 05-job_modules
        # (and don't use UTC as we use it in browser tests)
        last_seen_time => time2str('%Y-%m-%d %H:%M:%S', time - 100000),
        last_matched_module_id => 9,
        last_matched_time => time2str('%Y-%m-%d %H:%M:%S', time - 50000),
        file_present => 1,
        t_created => time2str('%Y-%m-%d %H:%M:%S', time - 200000),
        t_updated => time2str('%Y-%m-%d %H:%M:%S', time - 200000),
    }

]
