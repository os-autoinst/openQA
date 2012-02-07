#!/bin/bash

dburl=http://mozmill-crowd.brasstacks.mozilla.com/db/
dburl2=http://mozmill-archive.brasstacks.mozilla.com/db/
#time mozmill --report=$dburl -t mozmill-tests/firefox/
#echo "mozmill tests returned $?"
# test upstream nightly:
time mozmill-automation/testrun_functional.py --report=$dburl /tmp/firefox/firefox-bin
# test our build:
(cd mozmill-tests ; 
 hg rm firefox/restartTests/{testDefaultBookmarks,testSoftwareUpdateAutoProxy}/*.js
 hg rm firefox/testInstallation/testBreakpadInstalled.js
 hg rm tests/functional/restartTests/{testDefaultBookmarks,testSoftwareUpdateAutoProxy}/*.js tests/functional/testInstallation/testBreakpadInstalled.js
 hg commit -m "disable for openSUSE" -u bernhardtemp
)
#rm -rf mozmill-tests/firefox/restartTests/{testDefaultBookmarks,testSoftwareUpdateAutoProxy} 
time mozmill-automation/testrun_general.py --report=$dburl2 --repository=/tmp/mozmill-tests/ /usr/lib*/firefox/firefox-bin > /dev/ttyS0 2>&1
echo "mozmill testrun_general returned $?"
echo "mozmill testrun finished" > /dev/ttyS0
