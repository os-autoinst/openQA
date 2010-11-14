L=video/runlog.txt
newdays=4
#bwlimit=--bwlimit=1500
excludes=--exclude="*.zsync" --exclude="*DVD*" 
#excludes+=--exclude="*GNOME*"
#excludes+=--exclude="*i686*"
#excludes+=--exclude="*KDE*"
repoexcludes=--exclude="texlive*" 
#--max-delete=4000
#repoexcludes+=--exclude="x86_64"
#rsyncserver=rsync.opensuse.org
rsyncserver=stage.opensuse.org
dvdpath=/factory-all-dvd/iso/
testdir=testrun1
#dvdpath=/factory-all-dvd/11.3-isos/

all: sync prune list
cron: reposync sync prune newvideos
syncall: reposync sync gnomesync dvdsync promosync biarchsync

sync:
	for i in $(seq 1 36) ; do scripts/preparersync ; done
	/usr/local/bin/withlock sync.lock rsync -aPHv ${bwlimit} ${excludes} rsync://${rsyncserver}/opensuse-full-with-factory/opensuse/factory/iso/ factory/iso/

prune:
	-find factory/iso/ -type f -name \*.iso -atime +30 -print0 | xargs --no-run-if-empty -0 rm -f

prune2:
	-find factory/iso/ -type f -mtime +30 \( -name "*-NET-*iso" -o -name "*-KDE-*.iso" \) |sort|perl -ne 'if(($$n++%2)==0){print}' | xargs --no-run-if-empty rm -f 

list:
	ls factory/iso/*Build*.iso

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


ISOS=$(shell ls factory/iso/*Build*-Media.iso)
NEWISOS=$(shell find factory/iso/ -name "*Build*-Media.iso" ! -name "*-Addon-*" -mtime -$(newdays))
NEWNETISOS=$(shell find factory/iso/ \( -name "*NET*Build*-Media.iso" -o -name "*DVD*Build*-Media.iso" \) -mtime -$(newdays))
OGGS=$(patsubst factory/iso/%-Media.iso,video/%.ogv,$(ISOS))
NEWOGGS=$(patsubst factory/iso/%-Media.iso,video/%.ogv,$(NEWISOS))
allvideos: $(OGGS)
newvideos: $(NEWOGGS)
newlxdevideos: $(patsubst factory/iso/%-Media.iso,video/%-lxde.ogv,$(NEWNETISOS))
newxfcevideos: $(patsubst factory/iso/%-Media.iso,video/%-xfce.ogv,$(NEWNETISOS))
newgnomevideos: $(patsubst factory/iso/%-Media.iso,video/%-gnome.ogv,$(NEWNETISOS))

video/%.ogv: factory/iso/%-Media.iso
	in=$< out=$@ L=$L testdir=${testdir} tools/isotovideo2
	#echo in=$< out=$@
	#touch $@ # prevent cron going in here during test
	#echo `date` starting to create $@ >>$L
	#pwd=`pwd`; cd $(testdir) ; /usr/local/bin/withlock kvm.lock ../perl/autoinst/tools/isotovideo $$pwd/$<
	#echo `date` finished to create $@ >>$L
	#mv $(testdir)/video/* video/
	#-mv $(testdir)/testresults/* testresults/
	#mv -f $(testdir)/currentautoinst-log.txt $@.autoinst.txt

video/%-lxde.ogv: factory/iso/%-Media.iso
	export DESKTOP=lxde ; LVM=1 EXTRANAME=-$$DESKTOP in=$< out=$@ L=$L testdir=${testdir} tools/isotovideo2

video/%-xfce.ogv: factory/iso/%-Media.iso
	export DESKTOP=xfce ; EXTRANAME=-$$DESKTOP in=$< out=$@ L=$L testdir=${testdir} tools/isotovideo2
video/%-gnome.ogv: factory/iso/%-Media.iso
	export DESKTOP=gnome ; LVM=1 EXTRANAME=-$$DESKTOP in=$< out=$@ L=$L testdir=${testdir} tools/isotovideo2
	

%.ogg: %.mp3
	ffmpeg -ab 192k -i $< -acodec vorbis $@
%-music.ogv: %.ogv
	ffmpeg -t 100 -i $< -i /home/bernhard/public_html/mirror/opensuse/music/www.musopen.com/161.ogg -vcodec copy -acodec copy $@
	#ffmpeg -t 100 -i $< -i /home/bernhard/public_html/mirror/opensuse/music/www.musopen.com/161.ogg -vcodec copy -acodec copy -f ogg - | ffmpeg2theora -o $@ -
	#segfaults: ffmpeg -t 100 -b 20000k -i $< -i /home/bernhard/public_html/mirror/opensuse/music/www.musopen.com/161.mp3 -f ogg - | ffmpeg2theora -o $@ -
	#ffmpeg -t 100 -i $< -i /home/bernhard/public_html/mirror/opensuse/music/www.musopen.com/161.mp3 -vcodec copy $@

clean:
	rm -f factory/iso/*-current-Media.iso.zsync

