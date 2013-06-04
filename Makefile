L=runlog.txt
newdays=2
d=$(shell date +%Y%m%d)
#bwlimit=--bwlimit=1500
#excludes=--exclude="*.zsync" --exclude="*DVD*" 
#excludes+=--exclude="*GNOME*"
#excludes+=--exclude="*i686*"
#excludes+=--exclude="*KDE*"
excludes+=--exclude="*Addon*"
#repoexcludes=--exclude="texlive*"
#--max-delete=4000
#repoexcludes+=--exclude="x86_64"
#rsyncserver=rsync.opensuse.org
repourl=http://widehat.opensuse.org/repositories/
rsyncserver=stage.opensuse.org
dvdpath=/factory-all-dvd/iso/
testdir=pool/manual
buildnr=$(shell cat factory-testing/repo/oss/media.1/build)
testedbuildnr=$(shell cat factory-tested/repo/oss/media.1/build)
#dvdpath=/factory-all-dvd/11.3-isos/

all: sync prune list
cron: reposync sync prune prune2 newtests
syncall: reposync sync gnomesync dvdsync promosync biarchsync

sync:
	for i in $(seq 1 36) ; do scripts/preparersync ; done
	withlock sync.lock rsync -aPHv ${bwlimit} ${excludes} rsync://${rsyncserver}/opensuse-full-with-factory/opensuse/factory/iso/ factory/iso/

prune:
	-find liveiso/ factory/iso/ -type f -name \*.iso -atime +90 -mtime +90 -print0 | xargs --no-run-if-empty -0 rm -f
	make resultarchive
	-find testresults/ -atime +15 -mtime +25 -name \*.ppm -print0 | xargs --no-run-if-empty -0 gzip -9
	-find testresults/ video/ logs/ -type f -atime +100 -mtime +150 -print0 | xargs --no-run-if-empty -0 rm -f
	-df testresults/ |grep -q "9[0-9]%" && find testresults/ video/ -type f -atime +15 -mtime +25 |sort|perl -ne 'if(($$n++%2)==0){print}' | xargs --no-run-if-empty rm -f

prune2: dvdprune
	-df factory/iso/|grep -q "9[0-9]%" && find factory/iso/ -type f -mtime +20 -name "*.iso" |sort|perl -ne 'if(($$n++%2)==0){print}' | xargs --no-run-if-empty rm -f 
dvdprune:
	-df factory/iso/|grep -q "[8-9][0-9]%" &&find factory/iso/ -name "*-DVD-*.iso" -mtime +3 |sort|perl -ne 'if(($$n++%2)==0){print}' | xargs --no-run-if-empty rm -f
	-df testresults/ |grep -q "9[0-9]%" && find testresults/ -type f -mtime +37 |sort|perl -ne 'if(($$n++%2)==0){print}' | xargs --no-run-if-empty rm -f

prune3: 
	# only keep latest NET iso of each arch
	#find factory/iso/ -name "*-NET-*"|sort -t- -k4| perl -ne '...'

testrun: testresults/$t
	# just a shortcut

testcancel:
	find pool/ -name testname | while read line ; do test "`cat $$line`" == "$t" && cd `dirname $$line` && rm backend.run ; done

testloop:
	rm -f stopfile
	tools/testloop
updatechangedb:
	cd changedb ; find /opensuse/factory/repo/oss/ -mtime -7 -name \*.rpm | ./recentchanges.pl

recheck:
	cd perl/autoinst/ ; tools/rechecklog ../../testresults/$t/autoinst-log.txt
deleteresult:
	test -n "$t" && rm -rf testresults/$t
	find pool/ -name testname | while read line ; do test "`cat $$line`" == "$t" && rm $$line || : ; done
renameresult:
	mv -f testresults/$f testresults/$t
renamenetresults:
	n=`perl -e '$$_="${buildnr}";s/.*Build(\d+)/$$1/;print;'` ; echo $$n ;\
	make renameresult f=openSUSE-NET-i586-Build$f t=openSUSE-NET-i586-Build$f+$$n ;\
	make renameresult f=openSUSE-NET-x86_64-Build$f t=openSUSE-NET-x86_64-Build$f+$$n

list:
	ls factory/iso/*Build*.iso
status:
	ls factory-testing/iso/openSUSE-*x86_64-*
	cat factory*/repo/oss/media.1/build factory-tested/repo/oss/media.1/media /var/tmp/lastfactorysnapshotisobuildnr
	@echo

debiansync:
	wget -q -Ofactory/iso/debian-netinst-i386-testing-Media.iso http://cdimage.debian.org/cdimage/daily-builds/daily/arch-latest/i386/iso-cd/debian-testing-i386-netinst.iso
	wget -q -Ofactory/iso/debian-bc-i386-testing-Media.iso http://cdimage.debian.org/cdimage/daily-builds/daily/arch-latest/i386/iso-cd/debian-testing-i386-businesscard.iso
	wget -q -Ofactory/iso/debian-netinst-amd64-testing-Media.iso http://cdimage.debian.org/cdimage/daily-builds/daily/arch-latest/amd64/iso-cd/debian-testing-amd64-netinst.iso

fedorasync:
	wget -q -Ofactory/iso/fedora-netinst-i386-16-Media.iso http://mirror.fraunhofer.de/download.fedora.redhat.com/fedora/linux/releases/16/Fedora/i386/os/images/boot.iso

archlinuxsync: archbuild=$(shell curl -s http://releng.archlinux.org/isos/ | grep "Directory" | tail -n1 | sed -e 's#.*\/">\(.*\)<\/a>.*#\1#')
archlinuxsync: archbuild_local=$(shell echo -n $(archbuild) | awk -F '_' '{print $$1}')
archlinuxsync:
	wget -q -Ofactory/iso/archlinux-core-i686.iso http://releng.archlinux.org/isos/$(archbuild)/archlinux-$(archbuild)-core-i686.iso
	#wget -q -Ofactory/iso/archlinux-core-i686-$(archbuild_local).iso http://releng.archlinux.org/isos/$(archbuild)/archlinux-$(archbuild)-core-i686.iso
	#wget -q -Ofactory/iso/archlinux-core-x86_64-$(archbuild_local).iso http://releng.archlinux.org/isos/$(archbuild)/archlinux-$(archbuild)-core-x86_64.iso
	#wget -q -Ofactory/iso/archlinux-netinst-i686-$(archbuild_local).iso http://releng.archlinux.org/isos/$(archbuild)/archlinux-$(archbuild)-netinstall-i686.iso
	wget -q -Ofactory/iso/archlinux-netinst-x86_64.iso http://releng.archlinux.org/isos/$(archbuild)/archlinux-$(archbuild)-netinstall-x86_64.iso

dvdsync:
	-rsync -aPHv ${bwlimit} --exclude="*Biarch*" rsync://${rsyncserver}${dvdpath}openSUSE-DVD-*.iso factory/iso/
promosync:
	rsync -aPHv ${bwlimit} rsync://${rsyncserver}${dvdpath}openSUSE-Promo-*.iso factory/iso/
biarchsync:
	rsync -aPHv ${bwlimit} rsync://${rsyncserver}${dvdpath}openSUSE-DVD-Biarch-*.iso factory/iso/

#dvdsync:
#	curl -n https://api.opensuse.org/build/openSUSE:Factory/images/local/_product:openSUSE-dvd5-dvd-i586/

ftpsync:
	wget -nc -np -r http://ftp.gwdg.de/pub/opensuse/factory/iso/
	rm -f factory/iso/index.html*

gnomesync:
	rsync -aPHv ${bwlimit} rsync://${rsyncserver}/opensuse-full-with-factory/opensuse/factory/iso/*GNOME*.iso factory/iso/

getkdeunstable:
	wget -r -nc -np --accept "KDE4-UNSTABLE-Live*.iso" ${repourl}KDE:/Medias/images/iso/ #KDE4-UNSTABLE-Live.x86_64-4.5.77-Build2.3.iso
	tools/niceisonames widehat.opensuse.org/repositories/KDE:/Medias/images/iso/*.iso
getsmeegol:
	wget -r -nc -np --accept "Smeegol*.iso" ${repourl}Meego:/Netbook:/1.1/images/iso/
	tools/niceisonames widehat.opensuse.org/repositories/Meego:/Netbook:/1.1/images/iso/*.iso


zsync:	
	for type in NET KDE-LiveCD ; do \
		for arch in i586 i686 x86_64 ; do \
			x=`scripts/latestiso $$arch $$type`; test -z "$$x" || ln -f $$x factory/iso/openSUSE-$$type-$$arch-current-Media.iso ;\
		done ;\
	done
	$(MAKE) -C factory/iso/ -f ../../make/zsync.mk
	scripts/removeoldzsync

reposync:
	mkdir -p factory/repo/oss/suse/
	# first sync all big files without deleting. This keeps consistency
	# another sync in case server changed during first long sync
	for i in 1 2 3 ; do date=$$(date +%s) ; withlock reposync.lock rsync -aH ${bwlimit} ${repoexcludes} rsync://${rsyncserver}/opensuse-full-with-factory/opensuse/factory/repo/oss/suse/ factory/repo/oss/suse/ ; test $$(date +%s) -le $$(expr $$date + 200) && break ; done
	# copy meta-data ; delete old files as last step
	-rsync -aPHv --delete-after ${repoexcludes} rsync://${rsyncserver}/opensuse-full-with-factory/opensuse/factory/repo/ factory/repo/
preparesnapshot: sync reposync dvdsync updatechangedb
	mkdir -p factory-testing/repo/
	rsync -aSHPv --delete-after --link-dest=../factory/ rsync://${rsyncserver}/opensuse-full-with-factory/opensuse/factory/ factory-testing/
	make status

snapshot:
	mkdir -p factory-tested/repo/
	# link-dest is relative to dest dir
	rsync -aH --delete-after --link-dest=../factory-testing/ factory-testing/ factory-tested/
	tools/updateisobuildnr

resultarchive:
	mkdir -p archive/
	ln -f video/*.autoinst.txt archive/


ISOS=$(shell ls factory/iso/*Build*-Media.iso)

NEWISOS=$(shell find factory/iso/ -name "*[DN][VE][DT]*Build*-Media.iso" -mtime -$(newdays)|sort -r -t- -k4|head -8 ; find factory/iso/ -name "*Live*Build*-Media.iso" -mtime -$(newdays)|sort -r -t- -k5|head -4 ; find factory/iso/ -name "archlinux-*.iso" -mtime -$(newdays)|sort -r -t- -k5|head -4)
# it is enough to test one i586+x86_64 NET-iso
NEWNETISOS=$(shell find factory/iso/ -name "*NET*Build*-Media.iso" -mtime -${newdays}|sort -r -t- -k4|head -2 ; find factory/iso/ -name "*DVD*Build*-Media.iso" -mtime -${newdays})
TESTS=$(patsubst factory/iso/%-Media.iso,testresults/%,$(ISOS))
NEWTESTS=$(patsubst factory/iso/%-Media1.iso,testresults/%,$(NEWISOS))
scheduledtests=$(patsubst %,testresults/%,$(shell cd schedule.d/ ; ls ))
alltests: $(TESTS)
newtests: $(NEWTESTS) $(scheduledtests)
newlxdetests: $(patsubst factory/iso/%-Media.iso,testresults/%-lxde,$(NEWNETISOS))
newxfcetests: $(patsubst factory/iso/%-Media.iso,testresults/%-xfce,$(NEWNETISOS))
newgnometests: $(patsubst factory/iso/%-Media.iso,testresults/%-gnome,$(NEWNETISOS))
allnewtests: $(patsubst factory/iso/%-Media.iso,testresults/%,$(NEWISOS)) $(patsubst factory/iso/%-Media.iso,testresults/%-doc,$(NEWISOS)) $(patsubst factory/iso/%-Media.iso,testresults/%-lxde,$(NEWISOS)) $(patsubst factory/iso/%-Media.iso,testresults/%-xfce,$(NEWISOS)) $(patsubst factory/iso/%-Media.iso,testresults/%-gnome,$(NEWISOS)) $(patsubst factory/iso/%-Media.iso,testresults/%-minimalx,$(NEWISOS)) $(patsubst factory/iso/%-Media.iso,testresults/%-smp,$(NEWISOS)) $(patsubst factory/iso/%-Media.iso,testresults/%-textmode,$(NEWISOS)) $(patsubst factory/iso/%-Media.iso,testresults/%-usbboot,$(NEWISOS)) $(patsubst factory/iso/%-Media.iso,testresults/%-usbinst,$(NEWISOS)) $(patsubst factory/iso/%-Media.iso,testresults/%-nice,$(NEWISOS)) $(patsubst factory/iso/%-Media.iso,testresults/%-live,$(NEWISOS)) $(patsubst factory/iso/%-Media.iso,testresults/%-RAID0,$(NEWISOS)) $(patsubst factory/iso/%-Media.iso,testresults/%-RAID1,$(NEWISOS)) $(patsubst factory/iso/%-Media.iso,testresults/%-RAID10,$(NEWISOS)) $(patsubst factory/iso/%-Media.iso,testresults/%-RAID5,$(NEWISOS)) $(patsubst factory/iso/%-Media.iso,testresults/%-splitusr,$(NEWISOS)) $(patsubst factory/iso/%-Media.iso,testresults/%-cryptlvm,$(NEWISOS)) $(patsubst factory/iso/%-Media.iso,testresults/%-btrfscryptlvm,$(NEWISOS)) $(patsubst factory/iso/%-Media.iso,testresults/%-basesystemdevel,$(NEWISOS)) $(patsubst factory/iso/%-Media.iso,testresults/%-zyppdevel,$(NEWISOS)) $(patsubst factory/iso/%-Media.iso,testresults/%-yastdevel,$(NEWISOS)) $(patsubst factory/iso/%-Media.iso,testresults/%-kerneldevel,$(NEWISOS)) $(patsubst factory/iso/%-Media.iso,testresults/%-mozilladevel,$(NEWISOS)) $(patsubst factory/iso/%-Media.iso,testresults/%-xorgdevel,$(NEWISOS)) $(patsubst factory/iso/%-Media.iso,testresults/%-kdeplaygrounddevel,$(NEWISOS)) $(patsubst factory/iso/%-Media.iso,testresults/%-kdedevel,$(NEWISOS)) $(patsubst factory/iso/%-Media.iso,testresults/%-gnomedevel,$(NEWISOS)) $(patsubst factory/iso/%-Media.iso,testresults/%-xfcedevel,$(NEWISOS)) $(patsubst factory/iso/%-Media.iso,testresults/%-lxdedevel,$(NEWISOS)) $(patsubst factory/iso/%-Media.iso,testresults/%-uefi,$(NEWISOS)) $(patsubst factory/iso/%-Media.iso,testresults/%-btrfs,$(NEWISOS)) $(patsubst factory/iso/%-Media.iso,testresults/%-64,$(NEWISOS))

testresults/%: factory/iso/%-Media.iso
	in=$< out=$@ L=$L testdir=${testdir} tools/isotovideo2

testresults/%-doc: factory/iso/%-Media.iso
	DOCRUN=1 QEMUVGA=std in=$< out=$@ L=$L testdir=${testdir} tools/isotovideo2
testresults/%-de: factory/iso/%-Media.iso
	DOCRUN=1 INSTLANG=de_DE QEMUVGA=std in=$< out=$@ L=$L testdir=${testdir} tools/isotovideo2
testresults/%-lxde: factory/iso/%-Media.iso
	export DESKTOP=lxde ; LVM=1 EXTRANAME=-$$DESKTOP in=$< out=$@ L=$L testdir=${testdir} tools/isotovideo2

testresults/%-xfce: factory/iso/%-Media.iso
	export DESKTOP=xfce ; EXTRANAME=-$$DESKTOP in=$< out=$@ L=$L testdir=${testdir} tools/isotovideo2
testresults/%-gnome: factory/iso/%-Media.iso
	export DESKTOP=gnome ; LVM=1 EXTRANAME=-$$DESKTOP in=$< out=$@ L=$L testdir=${testdir} tools/isotovideo2
testresults/%-minimalx: factory/iso/%-Media.iso
	export DESKTOP=minimalx ; EXTRANAME=-$$DESKTOP in=$< out=$@ L=$L testdir=${testdir} tools/isotovideo2
testresults/%-smp: factory/iso/%-Media.iso
	QEMUCPUS=4 in=$< out=$@ L=$L testdir=${testdir} tools/isotovideo2
testresults/%-textmode: factory/iso/%-Media.iso
	export DESKTOP=textmode ; VIDEOMODE=text EXTRANAME=-$$DESKTOP in=$< out=$@ L=$L testdir=${testdir} tools/isotovideo2
testresults/%-usbboot: factory/iso/%-Media.iso
	USBBOOT=1 LIVETEST=1 in=$< out=$@ L=$L testdir=${testdir} tools/isotovideo2
testresults/%-usbinst: factory/iso/%-Media.iso
	USBBOOT=1 in=$< out=$@ L=$L testdir=${testdir} tools/isotovideo2
testresults/%-nice: factory/iso/%-Media.iso
	NICEVIDEO=1 DOCRUN=1 REBOOTAFTERINSTALL=0 SCREENSHOTINTERVAL=0.25 in=$< out=$@ L=$L testdir=${testdir} tools/isotovideo2
testresults/%-live: factory/iso/%-Media.iso
	LIVETEST=1 REBOOTAFTERINSTALL=0 in=$< out=$@ L=$L testdir=${testdir} tools/isotovideo2
testresults/%-RAID0: factory/iso/%-Media1.iso
	export RAIDLEVEL=`echo $@ | sed 's/.*RAID\([0-9]*\)\$$/\1/'` ; in=$< out=$@ L=$L testdir=${testdir} tools/isotovideo2
testresults/%-RAID1: factory/iso/%-Media1.iso
	export RAIDLEVEL=`echo $@ | sed 's/.*RAID\([0-9]*\)\$$/\1/'` ; in=$< out=$@ L=$L testdir=${testdir} tools/isotovideo2
testresults/%-RAID10: factory/iso/%-Media1.iso
	export RAIDLEVEL=10 ; in=$< out=$@ L=$L testdir=${testdir} tools/isotovideo2
testresults/%-RAID5: factory/iso/%-Media1.iso
	export RAIDLEVEL=5 ; in=$< out=$@ L=$L testdir=${testdir} tools/isotovideo2
testresults/%-splitusr: factory/iso/%-Media.iso
	SPLITUSR=1 in=$< out=$@ L=$L testdir=${testdir} tools/isotovideo2
testresults/%-cryptlvm: factory/iso/%-Media.iso
	REBOOTAFTERINSTALL=0 ENCRYPT=1 LVM=1 in=$< out=$@ L=$L testdir=${testdir} tools/isotovideo2
testresults/%-btrfscryptlvm: factory/iso/%-Media.iso
	BTRFS=1 ENCRYPT=1 LVM=1 in=$< out=$@ L=$L testdir=${testdir} tools/isotovideo2

# Debian
debian: debian-32 debian-64
debian-32: testresults/debian-netinst-i386-testing_$d testresults/debian-bc-i386-testing_$d
debian-64: testresults/debian-netinst-amd64-testing_$d testresults/debian-netinst-amd64-sid_$d
testresults/debian-%_$d: factory/iso/debian-%-Media.iso
	HTTPPROXY=10.0.2.2:3128 in=$< out=$@ L=$L testdir=${testdir} tools/isotovideo2
testresults/debian-%sid_$d: factory/iso/debian-%testing-Media.iso
	HTTPPROXY=10.0.2.2:3128 SID=1 in=$< out=$@ L=$L testdir=${testdir} tools/isotovideo2

# Fedora
fedora: fedora-32
fedora-32: testresults/fedora-netinst-i386-16_$d 
#testresults/fedora-netinst-i386-rawhide_$d
testresults/fedora-%_$d: factory/iso/fedora-%-Media.iso
	QEMUVGA=cirrus DISTRI=fedora-16 HTTPPROXY=10.0.2.2:3128 in=$< out=$@ L=$L testdir=${testdir} tools/isotovideo2
testresults/fedora-%rawhide_$d: factory/iso/fedora-%16-Media.iso
	RAWHIDE=1 QEMUVGA=cirrus DISTRI=fedora-16 HTTPPROXY=10.0.2.2:3128 in=$< out=$@ L=$L testdir=${testdir} tools/isotovideo2

# Arch
archlinux: archlinux-32 archlinux-64
archlinux-32: testresults/archlinux-core-i686-$d
archlinux-64: testresults/archlinux-netinst-x86_64-$d
#archlinux-64: testresults/archlinux-core-x86_64-$d testresults/archlinux-netinst-x86_64-$d
testresults/archlinux-%-$d: factory/iso/archlinux-%.iso
	HTTPPROXY=10.0.2.2:3128 in=$< out=$@ L=$L testdir=${testdir} tools/isotovideo2

Tumbleweed-gnome32: testresults/openSUSE-Tumbleweed-i586-$d-11.4gnome32
testresults/openSUSE-Tumbleweed-i586-$d-11.4gnome32: distribution/11.4/iso/openSUSE-DVD-i586-11.4dummy.iso
	export ZDUPREPOS=http://download.opensuse.org/repositories/openSUSE:/Tumbleweed:/Testing/openSUSE_Tumbleweed_standard/ export UPGRADE=/space2/opensuse/img/opensuse-11.4-gnome-32.img ; TUMBLEWEED=1 NOINSTALL=1 ZDUP=1 DESKTOP=gnome KEEPHDDS=1 in=$< out=$@ L=$L testdir=${testdir} tools/isotovideo2
Tumbleweed-kde64: testresults/openSUSE-Tumbleweed-x86_64-$d-11.4kde64
testresults/openSUSE-Tumbleweed-x86_64-$d-11.4kde64: distribution/11.4/iso/openSUSE-DVD-x86_64-11.4dummy.iso
	export ZDUPREPOS=http://download.opensuse.org/repositories/openSUSE:/Tumbleweed:/Testing/openSUSE_Tumbleweed_standard/ export UPGRADE=/space2/opensuse/img/opensuse-11.4-kde-64.img ; TUMBLEWEED=1 NOINSTALL=1 ZDUP=1 DESKTOP=kde KEEPHDDS=1 in=$< out=$@ L=$L testdir=${testdir} tools/isotovideo2
Evergreen-gnome32: testresults/openSUSE-Evergreen-i586-$d-11.4gnome32
testresults/openSUSE-Evergreen-i586-$d-11.4gnome32: distribution/11.4/iso/openSUSE-DVD-i586-11.4dummy.iso
	export ZDUPREPOS=http://download.opensuse.org/repositories/openSUSE:/Evergreen:/11.4/standard/ ; export UPGRADE=/space2/opensuse/img/opensuse-11.4-gnome-32.img ; EVERGREEN=1 NOINSTALL=1 ZDUP=1 DESKTOP=gnome KEEPHDDS=1 in=$< out=$@ L=$L testdir=${testdir} tools/isotovideo2
Evergreen-11.2: testresults/openSUSE-Evergreen-x86_64-$d-11.2
testresults/openSUSE-Evergreen-x86_64-$d-11.2: distribution/11.4/iso/openSUSE-DVD-i586-11.4dummy.iso
	export ZDUPREPOS=http://download.opensuse.org/repositories/openSUSE:/Evergreen:/11.2:/Test/standard/ ; export UPGRADE=/space/bernhard/img/opensuse-112-64.img ; EVERGREEN=1 NOINSTALL=1 ZDUP=1 DESKTOP=kde in=$< out=$@ L=$L testdir=${testdir} tools/isotovideo2
testresults/%-12.2xfce32dup: factory/iso/%-Media.iso
	export UPGRADE=/opensuse/img/openSUSE-12.2-xfce.qcow2 ; DESKTOP=xfce KEEPHDDS=1 in=$< out=$@ L=$L testdir=${testdir} tools/isotovideo2
testresults/%-12.2xfce32zdup: factory/iso/%-Media.iso
	export UPGRADE=/opensuse/img/openSUSE-12.2-xfce.qcow2 ; NOINSTALL=1 ZDUP=1 DESKTOP=xfce KEEPHDDS=1 in=$< out=$@ L=$L testdir=${testdir} tools/isotovideo2
testresults/%-12.1gnome32dup: factory/iso/%-Media.iso
	export UPGRADE=/space2/opensuse/img/opensuse-12.1-gnome-32.img ; DESKTOP=gnome KEEPHDDS=1 in=$< out=$@ L=$L testdir=${testdir} tools/isotovideo2
testresults/%-12.1gnome32zdup: factory/iso/%-Media.iso
	export UPGRADE=/space2/opensuse/img/opensuse-12.1-gnome-32.img ; NOINSTALL=1 ZDUP=1 DESKTOP=gnome KEEPHDDS=1 in=$< out=$@ L=$L testdir=${testdir} tools/isotovideo2
testresults/%-11.4kde64zdup: factory/iso/%-Media.iso
	export UPGRADE=/space2/opensuse/img/opensuse-11.4-kde-64.img ; NOINSTALL=1 ZDUP=1 DESKTOP=kde KEEPHDDS=1 in=$< out=$@ L=$L testdir=${testdir} tools/isotovideo2
testresults/%-11.4kde64dup: factory/iso/%-Media.iso
	export UPGRADE=/space2/opensuse/img/opensuse-11.4-kde-64.img ; DESKTOP=kde KEEPHDDS=1 in=$< out=$@ L=$L testdir=${testdir} tools/isotovideo2
testresults/%-11.4gnome32zdup: factory/iso/%-Media.iso
	export UPGRADE=/space2/opensuse/img/opensuse-11.4-gnome-32.img ; NOINSTALL=1 ZDUP=1 DESKTOP=gnome KEEPHDDS=1 in=$< out=$@ L=$L testdir=${testdir} tools/isotovideo2
testresults/%-11.4gnome32dup: factory/iso/%-Media.iso
	export UPGRADE=/space2/opensuse/img/opensuse-11.4-gnome-32.img ; DESKTOP=gnome KEEPHDDS=1 in=$< out=$@ L=$L testdir=${testdir} tools/isotovideo2
testresults/%-11.4ms5gnomedup: factory/iso/%-Media.iso
	export UPGRADE=/space2/opensuse/img/opensuse-11.4-ms5-gnome-64.img ; DESKTOP=gnome KEEPHDDS=1 in=$< out=$@ L=$L testdir=${testdir} tools/isotovideo2
testresults/%-11.3gnomedup: factory/iso/%-Media.iso
	export UPGRADE=/space/bernhard/img/opensuse-113-64-gnome.img ; DESKTOP=gnome KEEPHDDS=1 in=$< out=$@ L=$L testdir=${testdir} tools/isotovideo2
testresults/%-11.3zdup: factory/iso/%-Media.iso
	export UPGRADE=/space2/opensuse/img/opensuse-11.3-32.img ; NOINSTALL=1 ZDUP=1 DESKTOP=kde KEEPHDDS=1 in=$< out=$@ L=$L testdir=${testdir} tools/isotovideo2
testresults/%-11.3dupb: factory/iso/%-Media.iso
	export UPGRADE=/space2/tmp/opensuse-113-32-updated.img ; KEEPHDDS=1 in=$< out=$@ L=$L testdir=${testdir} tools/isotovideo2
testresults/%-11.3dup: factory/iso/%-Media.iso
	export UPGRADE=/space2/opensuse/img/opensuse-11.3-32.img ; KEEPHDDS=1 in=$< out=$@ L=$L testdir=${testdir} tools/isotovideo2
testresults/%-11.2zdup: factory/iso/%-Media.iso
	export UPGRADE=/space/bernhard/img/opensuse-112-64.img ; NOINSTALL=1 ZDUP=1 DESKTOP=kde in=$< out=$@ L=$L testdir=${testdir} tools/isotovideo2
testresults/%-11.2dup: factory/iso/%-Media.iso
	export UPGRADE=/space/bernhard/img/opensuse-112-64.img ; in=$< out=$@ L=$L testdir=${testdir} tools/isotovideo2
testresults/%-11.1dup: factory/iso/%-Media.iso
	export UPGRADE=/space/bernhard/img/opensuse-111-64.img ; HDDMODEL=ide KEEPHDDS=1 in=$< out=$@ L=$L testdir=${testdir} tools/isotovideo2

testresults/%-basesystemdevel: factory/iso/%-Media.iso
	ADDONURL=${repourl}Base:/System/openSUSE_Factory/ in=$< out=$@ L=$L testdir=${testdir} tools/isotovideo2
testresults/%-zyppdevel: factory/iso/%-Media.iso
	ADDONURL=${repourl}zypp:/Head/openSUSE_Factory/ in=$< out=$@ L=$L testdir=${testdir} tools/isotovideo2
testresults/%-yastdevel: factory/iso/%-Media.iso
	ADDONURL=${repourl}YaST:/Head/openSUSE_Factory/ in=$< out=$@ L=$L testdir=${testdir} tools/isotovideo2
testresults/%-kerneldevel: factory/iso/%-Media.iso
	ADDONURL=${repourl}Kernel:/HEAD/standard/ in=$< out=$@ L=$L testdir=${testdir} tools/isotovideo2
testresults/%-mozilladevel: factory/iso/%-Media.iso
	BIGTEST=1 DESKTOP=gnome ADDONURL=${repourl}mozilla:/beta/SUSE_Factory/+${repourl}LibreOffice:/Unstable/openSUSE_Factory/ in=$< out=$@ L=$L testdir=${testdir} tools/isotovideo2
testresults/%-xorgdevel: factory/iso/%-Media.iso
	ADDONURL=${repourl}X11:/XOrg/openSUSE_Factory/ LVM=1 in=$< out=$@ L=$L testdir=${testdir} tools/isotovideo2
	#ADDONURL=${repourl}X11:/XOrg/openSUSE_Factory/+${repourl}Kernel:/HEAD/openSUSE_Factory/ LVM=1 in=$< out=$@ L=$L testdir=${testdir} tools/isotovideo2
testresults/%-kdeplaygrounddevel: factory/iso/%-Media.iso
	ADDONURL=${repourl}KDE:/Unstable:/Playground/openSUSE_Factory/ in=$< out=$@ L=$L testdir=${testdir} tools/isotovideo2
testresults/%-kdedevel: factory/iso/%-Media.iso
	ADDONURL=${repourl}KDE:/Distro:/Factory/openSUSE_Factory/+${repourl}LibreOffice:/Unstable/openSUSE_Factory/ in=$< out=$@ L=$L testdir=${testdir} tools/isotovideo2
testresults/%-gnomedevel: factory/iso/%-Media.iso
	DESKTOP=gnome ADDONURL=${repourl}GNOME:/Factory/openSUSE_Factory/ in=$< out=$@ L=$L testdir=${testdir} tools/isotovideo2
testresults/%-xfcedevel: factory/iso/%-Media.iso
	DESKTOP=xfce ADDONURL=${repourl}X11:/xfce/openSUSE_Factory/ in=$< out=$@ L=$L testdir=${testdir} tools/isotovideo2
testresults/%-lxdedevel: factory/iso/%-Media.iso
	DESKTOP=lxde ADDONURL=${repourl}X11:/lxde/openSUSE_Factory/ in=$< out=$@ L=$L testdir=${testdir} tools/isotovideo2
testresults/%-uefi: factory/iso/%-Media.iso
	UEFI=/openqa/uefi DESKTOP=lxde in=$< out=$@ L=$L testdir=${testdir} tools/isotovideo2
testresults/%-btrfs: factory/iso/%-Media.iso
	BTRFS=1 in=$< out=$@ L=$L testdir=${testdir} tools/isotovideo2
testresults/%-se: factory/iso/%-Media.iso
	INSTLANG=sv_SE in=$< out=$@ L=$L testdir=${testdir} tools/isotovideo2
testresults/%-es: factory/iso/%-Media.iso
	INSTLANG=es_ES in=$< out=$@ L=$L testdir=${testdir} tools/isotovideo2
testresults/%-dk: factory/iso/%-Media.iso
	INSTLANG=da_DK in=$< out=$@ L=$L testdir=${testdir} tools/isotovideo2
testresults/%-64: factory/iso/%-Media.iso
	QEMUCPU=qemu64 in=$< out=$@ L=$L testdir=${testdir} tools/isotovideo2
testresults/openSUSE-%: liveiso/openSUSE-%.iso
	LIVEOBSWORKAROUND=1 LIVECD=1 LIVETEST=1 in=$< out=$@ L=$L testdir=${testdir} tools/isotovideo2


	

%.ogg: %.mp3
	ffmpeg -ab 192k -i $< -acodec vorbis $@
%-music.ogv: %.ogv
	ffmpeg -t 100 -i $< -i /home/bernhard/public_html/mirror/opensuse/music/www.musopen.com/161.ogg -vcodec copy -acodec copy $@
	#ffmpeg -t 100 -i $< -i /home/bernhard/public_html/mirror/opensuse/music/www.musopen.com/161.ogg -vcodec copy -acodec copy -f ogg - | ffmpeg2theora -o $@ -
	#segfaults: ffmpeg -t 100 -b 20000k -i $< -i /home/bernhard/public_html/mirror/opensuse/music/www.musopen.com/161.mp3 -f ogg - | ffmpeg2theora -o $@ -
	#ffmpeg -t 100 -i $< -i /home/bernhard/public_html/mirror/opensuse/music/www.musopen.com/161.mp3 -vcodec copy $@

gitcollect:
	#rsync -a /srv/www/ www/
	rsync -a /usr/local/bin/umlffmpeg ./tools/
	rsync -a /etc/apparmor.d/{srv.www,usr.sbin.{httpd,rsyncd}}* etc/apparmor.d
	cp -a --parent /etc/apparmor.d/{tunables,abstractions}/openqa* /etc/apparmor.d/abstractions/imagemagick .
	rsync -a /etc/apache2/conf.d/openqa.conf etc/apache2/conf.d/

janitor:
	git update-server-info
	cd qatests/xfstests ; git pull ; git update-server-info #from git clone git://oss.sgi.com/xfs/cmds/xfstests
	cd qatests/xfsprogs ; git pull ; git update-server-info

clean:
	rm -f factory/iso/*-current-Media.iso.zsync
	rm -rf pool/*/{testresults,raid,qemuscreenshot}/*
	rmdir --ignore-fail-on-non-empty testresults/*
	rm -f pool/*/qemu.pid

