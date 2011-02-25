L=video/runlog.txt
newdays=2
#bwlimit=--bwlimit=1500
excludes=--exclude="*.zsync" --exclude="*DVD*" 
#excludes+=--exclude="*GNOME*"
#excludes+=--exclude="*i686*"
#excludes+=--exclude="*KDE*"
#repoexcludes=--exclude="texlive*"
#--max-delete=4000
#repoexcludes+=--exclude="x86_64"
#rsyncserver=rsync.opensuse.org
repourl=http://widehat.opensuse.org/repositories/
rsyncserver=stage.opensuse.org
dvdpath=/factory-all-dvd/iso/
testdir=testrun-manual
buildnr=$(shell cat factory-testing/repo/oss/media.1/build)
testedbuildnr=$(shell cat factory-tested/repo/oss/media.1/build)
#dvdpath=/factory-all-dvd/11.3-isos/

all: sync prune list
cron: reposync sync prune prune2 newvideos
syncall: reposync sync gnomesync dvdsync promosync biarchsync

sync:
	for i in $(seq 1 36) ; do scripts/preparersync ; done
	/usr/local/bin/withlock sync.lock rsync -aPHv ${bwlimit} ${excludes} rsync://${rsyncserver}/opensuse-full-with-factory/opensuse/factory/iso/ factory/iso/

prune:
	-find liveiso/ factory/iso/ -type f -name \*.iso -atime +90 -mtime +90 -print0 | xargs --no-run-if-empty -0 rm -f
	make resultarchive
	-find testresults/ video/ -type f -name \*.iso -atime +150 -mtime +150 -print0 | xargs --no-run-if-empty -0 rm -f

prune2: dvdprune
	-df factory/iso/|grep -q "9[0-9]%" && find factory/iso/ -type f -mtime +20 -name "*.iso" |sort|perl -ne 'if(($$n++%2)==0){print}' | xargs --no-run-if-empty rm -f 
dvdprune:
	-df factory/iso/|grep -q "[8-9][0-9]%" &&find factory/iso/ -name "*-DVD-*.iso" -mtime +3 |sort|perl -ne 'if(($$n++%2)==0){print}' | xargs --no-run-if-empty rm -f
	-df testresults/ |grep -q "9[0-9]%" && find testresults/ -type f -mtime +37 |sort|perl -ne 'if(($$n++%2)==0){print}' | xargs --no-run-if-empty rm -f

prune3: 
	# only keep latest NET iso of each arch
	#find factory/iso/ -name "*-NET-*"|sort -t- -k4| perl -ne '...'

deleteresult:
	rm -f video/$t.ogv
	rm -f video/$t.ogv.autoinst.txt
	rm -rf testresults/$t
renameresult:
	mv -f video/$f.ogv video/$t.ogv
	mv -f video/$f.ogv.autoinst.txt video/$t.ogv.autoinst.txt
	mv -f testresults/$f testresults/$t
renamenetresults:
	n=`perl -e '$$_="${buildnr}";s/.*Build(\d+)/$$1/;print;'` ; echo $$n ;\
	make renameresult f=openSUSE-NET-i586-Build$f t=openSUSE-NET-i586-Build$f+$$n ;\
	make renameresult f=openSUSE-NET-x86_64-Build$f t=openSUSE-NET-x86_64-Build$f+$$n
	

list:
	ls factory/iso/*Build*.iso
status:
	ls factory-testing/iso/openSUSE-*x86_64-*
	cat factory*/repo/oss/media.1/build /var/tmp/lastfactorysnapshotisobuildnr
	@echo

dvdsync:
	rsync -aPHv ${bwlimit} --exclude="*Biarch*" rsync://${rsyncserver}${dvdpath}openSUSE-DVD-*.iso factory/iso/
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
	for i in 1 2 3 ; do date=$$(date +%s) ; /usr/local/bin/withlock reposync.lock rsync -aH ${bwlimit} ${repoexcludes} rsync://${rsyncserver}/opensuse-full-with-factory/opensuse/factory/repo/oss/suse/ factory/repo/oss/suse/ ; test $$(date +%s) -le $$(expr $$date + 200) && break ; done
	# copy meta-data ; delete old files as last step
	-rsync -aPHv --delete-after ${repoexcludes} rsync://${rsyncserver}/opensuse-full-with-factory/opensuse/factory/repo/ factory/repo/
preparesnapshot: sync reposync dvdsync
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
NEWISOS=$(shell find factory/iso/ -name "*[DN][VE][DT]*Build*-Media.iso" -mtime -$(newdays)|sort -r -t- -k4|head -8 ; find factory/iso/ -name "*LiveCD*Build*-Media.iso" -mtime -$(newdays)|sort -r -t- -k5|head -4)
# it is enough to test one i586+x86_64 NET-iso
NEWNETISOS=$(shell find factory/iso/ -name "*NET*Build*-Media.iso" -mtime -${newdays}|sort -r -t- -k4|head -2 ; find factory/iso/ -name "*DVD*Build*-Media.iso" -mtime -${newdays})
OGGS=$(patsubst factory/iso/%-Media.iso,video/%.ogv,$(ISOS))
NEWOGGS=$(patsubst factory/iso/%-Media.iso,video/%.ogv,$(NEWISOS)) $(patsubst factory/iso/%-Media.iso,video/%-gnome.ogv,$(NEWNETISOS)) $(patsubst factory/iso/%-Media.iso,video/%-lxde.ogv,$(NEWNETISOS))
allvideos: $(OGGS)
newvideos: $(NEWOGGS)
newlxdevideos: $(patsubst factory/iso/%-Media.iso,video/%-lxde.ogv,$(NEWNETISOS))
newxfcevideos: $(patsubst factory/iso/%-Media.iso,video/%-xfce.ogv,$(NEWNETISOS))
newgnomevideos: $(patsubst factory/iso/%-Media.iso,video/%-gnome.ogv,$(NEWNETISOS))

video/%.ogv: factory/iso/%-Media.iso
	in=$< out=$@ L=$L testdir=${testdir} tools/isotovideo2

video/%-lxde.ogv: factory/iso/%-Media.iso
	export DESKTOP=lxde ; LVM=1 EXTRANAME=-$$DESKTOP in=$< out=$@ L=$L testdir=${testdir} tools/isotovideo2

video/%-xfce.ogv: factory/iso/%-Media.iso
	export DESKTOP=xfce ; EXTRANAME=-$$DESKTOP in=$< out=$@ L=$L testdir=${testdir} tools/isotovideo2
video/%-gnome.ogv: factory/iso/%-Media.iso
	export DESKTOP=gnome ; LVM=1 EXTRANAME=-$$DESKTOP in=$< out=$@ L=$L testdir=${testdir} tools/isotovideo2
video/%-usbboot.ogv: factory/iso/%-Media.iso
	USBBOOT=1 LIVETEST=1 in=$< out=$@ L=$L testdir=${testdir} tools/isotovideo2
video/%-nice.ogv: factory/iso/%-Media.iso
	NICEVIDEO=1 SCREENSHOTINTERVAL=0.25 in=$< out=$@ L=$L testdir=${testdir} tools/isotovideo2
video/%-live.ogv: factory/iso/%-Media.iso
	LIVETEST=1 in=$< out=$@ L=$L testdir=${testdir} tools/isotovideo2
video/%-RAID10.ogv: factory/iso/%-Media.iso
	export RAIDLEVEL=10 ; in=$< out=$@ L=$L testdir=${testdir} tools/isotovideo2
video/%-RAID5.ogv: factory/iso/%-Media.iso
	export RAIDLEVEL=5 ; in=$< out=$@ L=$L testdir=${testdir} tools/isotovideo2
video/%-11.4ms5gnomedup.ogv: factory/iso/%-Media.iso
	export UPGRADE=/space2/opensuse/img/opensuse-11.4-ms5-gnome-64.img ; DESKTOP=gnome KEEPHDDS=1 in=$< out=$@ L=$L testdir=${testdir} tools/isotovideo2
video/%-11.3gnomedup.ogv: factory/iso/%-Media.iso
	export UPGRADE=/space/bernhard/img/opensuse-113-64-gnome.img ; DESKTOP=gnome KEEPHDDS=1 in=$< out=$@ L=$L testdir=${testdir} tools/isotovideo2
video/%-11.3dup.ogv: factory/iso/%-Media.iso
	export UPGRADE=/space2/opensuse/img/opensuse-11.3-32.img ; KEEPHDDS=1 in=$< out=$@ L=$L testdir=${testdir} tools/isotovideo2
video/%-11.2dup.ogv: factory/iso/%-Media.iso
	export UPGRADE=/space/bernhard/img/opensuse-112-64.img ; in=$< out=$@ L=$L testdir=${testdir} tools/isotovideo2
video/%-11.1dup.ogv: factory/iso/%-Media.iso
	export UPGRADE=/space/bernhard/img/opensuse-111-64.img ; HDDMODEL=ide KEEPHDDS=1 in=$< out=$@ L=$L testdir=${testdir} tools/isotovideo2

video/%-basesystemdevel.ogv: factory/iso/%-Media.iso
	ADDONURL=${repourl}Base:/System/openSUSE_Factory/ in=$< out=$@ L=$L testdir=${testdir} tools/isotovideo2
video/%-kerneldevel.ogv: factory/iso/%-Media.iso
	ADDONURL=${repourl}Kernel:/HEAD/openSUSE_Factory/ in=$< out=$@ L=$L testdir=${testdir} tools/isotovideo2
video/%-mozilladevel.ogv: factory/iso/%-Media.iso
	BIGTEST=1 DESKTOP=gnome ADDONURL=${repourl}mozilla:/beta/SUSE_Factory/+${repourl}LibreOffice:/Unstable/openSUSE_Factory/ in=$< out=$@ L=$L testdir=${testdir} tools/isotovideo2
video/%-xorgdevel.ogv: factory/iso/%-Media.iso
	ADDONURL=${repourl}X11:/XOrg/openSUSE_Factory/ LVM=1 in=$< out=$@ L=$L testdir=${testdir} tools/isotovideo2
	#ADDONURL=${repourl}X11:/XOrg/openSUSE_Factory/+${repourl}Kernel:/HEAD/openSUSE_Factory/ LVM=1 in=$< out=$@ L=$L testdir=${testdir} tools/isotovideo2
video/%-kdeplaygrounddevel.ogv: factory/iso/%-Media.iso
	ADDONURL=${repourl}KDE:/Unstable:/Playground/openSUSE_Factory/ in=$< out=$@ L=$L testdir=${testdir} tools/isotovideo2
video/%-kdedevel.ogv: factory/iso/%-Media.iso
	ADDONURL=${repourl}KDE:/Distro:/Factory/openSUSE_Factory/+${repourl}LibreOffice:/Unstable/openSUSE_Factory/ in=$< out=$@ L=$L testdir=${testdir} tools/isotovideo2
video/%-gnomedevel.ogv: factory/iso/%-Media.iso
	DESKTOP=gnome ADDONURL=${repourl}GNOME:/Factory/openSUSE_Factory/ in=$< out=$@ L=$L testdir=${testdir} tools/isotovideo2
video/%-xfcedevel.ogv: factory/iso/%-Media.iso
	DESKTOP=xfce ADDONURL=${repourl}X11:/xfce/openSUSE_Factory/ in=$< out=$@ L=$L testdir=${testdir} tools/isotovideo2
video/%-lxdedevel.ogv: factory/iso/%-Media.iso
	DESKTOP=lxde ADDONURL=${repourl}X11:/lxde/openSUSE_Factory/ in=$< out=$@ L=$L testdir=${testdir} tools/isotovideo2
video/%-se.ogv: factory/iso/%-Media.iso
	INSTLANG=sv_SE in=$< out=$@ L=$L testdir=${testdir} tools/isotovideo2
video/%-es.ogv: factory/iso/%-Media.iso
	INSTLANG=es_ES in=$< out=$@ L=$L testdir=${testdir} tools/isotovideo2
video/%-dk.ogv: factory/iso/%-Media.iso
	INSTLANG=da_DK in=$< out=$@ L=$L testdir=${testdir} tools/isotovideo2
video/%-64.ogv: factory/iso/%-Media.iso
	QEMUCPU=qemu64 in=$< out=$@ L=$L testdir=${testdir} tools/isotovideo2
video/openSUSE-%.ogv: liveiso/openSUSE-%.iso
	LIVEOBSWORKAROUND=1 LIVECD=1 LIVETEST=1 in=$< out=$@ L=$L testdir=${testdir} tools/isotovideo2


	

%.ogg: %.mp3
	ffmpeg -ab 192k -i $< -acodec vorbis $@
%-music.ogv: %.ogv
	ffmpeg -t 100 -i $< -i /home/bernhard/public_html/mirror/opensuse/music/www.musopen.com/161.ogg -vcodec copy -acodec copy $@
	#ffmpeg -t 100 -i $< -i /home/bernhard/public_html/mirror/opensuse/music/www.musopen.com/161.ogg -vcodec copy -acodec copy -f ogg - | ffmpeg2theora -o $@ -
	#segfaults: ffmpeg -t 100 -b 20000k -i $< -i /home/bernhard/public_html/mirror/opensuse/music/www.musopen.com/161.mp3 -f ogg - | ffmpeg2theora -o $@ -
	#ffmpeg -t 100 -i $< -i /home/bernhard/public_html/mirror/opensuse/music/www.musopen.com/161.mp3 -vcodec copy $@

gitcollect:
	rsync -a /srv/www/ www/
	rsync -a /usr/local/bin/umlffmpeg ./tools/
	rsync -a /etc/apparmor.d/{srv.www,usr.sbin.{httpd,rsyncd}}* etc/apparmor.d
	cp -a --parent /etc/apparmor.d/{tunables,abstractions}/openqa* .
	rsync -a /etc/apache2/conf.d/openqa.conf etc/apache2/conf.d/

janitor:
	git update-server-info

clean:
	rm -f factory/iso/*-current-Media.iso.zsync
	rm -rf /mnt/ssd/pool/*/testresults/*

