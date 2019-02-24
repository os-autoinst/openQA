m4_dnl Comment below applies to generated file, not to this template
# This Dockfile was generated from openQA Makefile with command
`# m4 -P -D M4_TEST='M4_TEST `-D M4_BASEIMAGE='M4_BASEIMAGE docker/direct_test.m4
# And must be called from openQA project folder like
# docker -f docker/<thisfile> .
m4_ifelse(M4_BASEIMAGE,`',m4_include(docker/direct_test_cache),FROM M4_BASEIMAGE)
m4_divert(-1)
m4_define(`clone_autoinst',`
WORKDIR /opt/os-autoinst
RUN git clone --depth=1 https://github.com/os-autoinst/os-autoinst ../os-autoinst
RUN autoreconf -f -i  && ./configure && make')
m4_define(`bus_start',`eval $(dbus-launch --sh-syntax)')
m4_divert(0)
m4_ifelse(FULLSTACK,`1',`
'clone_autoinst`
ENV FULL`'`'STACK 1
ENV DEVELOPER_FULLSTACK 1
ENV SCHEDULER_FULLSTACK 1')
WORKDIR /opt/testing_area
m4_ifdef(`COVER_OPTS',`COPY . .'
`RUN mkdir covers',`
COPY assets ./assets
COPY cpanfile ./
COPY .perltidyrc ./
COPY dbicdh ./dbicdh
COPY lib ./lib
COPY script ./script
COPY t/ ./t
COPY templates/ ./templates
')
# must retry because it uses external resourses which sporadically return 404
# if still failing - let it go: maybe it will succeed from tests or tests will not need this
RUN ( ./script/generate-packed-assets ./ || ( sleep 3; ./script/generate-packed-assets ./ ) || ( sleep 15; ./script/generate-packed-assets ./ ) || true )
ENV OPENQA_USE_DEFAULTS 1
RUN chown -R $NORMAL_USER:users .
m4_ifelse(FULLSTACK,`1',`RUN chown -R $NORMAL_USER:users ../os-autoinst', `')
USER ${NORMAL_USER}
ENV USER ${NORMAL_USER}
# install eventual dependencies which may be missing in base image
RUN cpanm -n --mirror http://no.where/ --installdeps .
m4_divert(-1)
m4_define(`DB_PATTERN',`"(Test::Database|OpenQA::Test::Case|OpenQA::Schema|setup_database)"')
m4_define(`db_setup',
ENV TEST_PG='DBI:Pg:dbname=openqa_test;host=/opt/testing_area/tpg'
RUN t/test_postgresql /opt/testing_area/tpg
RUN mkdir db
# cannot use /dev/shm/tpg in Dockerfile as it will not survive between RUN commands
ENV STARTDB='pg_ctl -w -D /opt/testing_area/tpg -l logfile start')
m4_syscmd(`grep -q -E' DB_PATTERN M4_TEST)
m4_divert(0)
m4_ifelse(m4_sysval, `0', `db_setup',`')
m4_divert(-1)
m4_define(`foreach',`m4_ifelse(m4_eval($#>2),1,
`m4_pushdef(`$1',`$3')$2`'m4_popdef(`$1')m4_dnl
`'m4_ifelse(m4_eval($#>3),1,`$0(`$1',`$2',m4_shift(m4_shift(m4_shift($@))))')')')
m4_changecom(BC,EC)m4_define(`TCMD',m4_ifdef(`COVER_OPTS',`cover COVER_OPTS --no-summary -test -make "prove -v Xfile # " covers/``''M4_COUNT',`prove -v Xfile'))
m4_define(`RUNCMD',RUN TCMD
)
m4_define(`RUNDBCMD',RUN ( $STARTDB && TCMD )
)
m4_define(`RUNDBBUSCMD',RUN ( $STARTDB && bus_start && TCMD )
)
m4_define(M4_COUNT,1)
m4_divert(0)
m4_ifdef(`COVER_OPTS',m4_ifelse(FULLSTACK,1,`',m4_define(`Xfile',t/01-compile-check-all.t)RUN TCMD`'m4_define(`M4_COUNT',m4_incr(M4_COUNT))))
m4_divert(-1)
m4_define(`GREP_NO_DB_PATTERN',`grep -L -E DB_PATTERN M4_TEST | tr "\n"' ``, | head -c -1'')
m4_define(`GREP_DB_PATTERN',`grep -l -E DB_PATTERN M4_TEST | tr "\n"' ``, | head -c -1'')
m4_syscmd(test $(GREP_NO_DB_PATTERN | wc -c) -gt 3)
m4_divert(-m4_sysval)
foreach(`Xfile',`RUNCMD`'m4_define(`M4_COUNT',m4_incr(M4_COUNT))', m4_esyscmd(GREP_NO_DB_PATTERN))
m4_syscmd(test $(GREP_DB_PATTERN | wc -c) -gt 3)
m4_divert(-m4_sysval)
foreach(`Xfile',`m4_ifelse(FULLSTACK,1,RUNDBBUSCMD,Xfile,t/14-grutasks.t,RUNDBBUSCMD,RUNDBCMD)'`m4_define(`M4_COUNT',m4_incr(M4_COUNT))', m4_esyscmd(GREP_DB_PATTERN))
m4_ifdef(`COVER_REPORT_OPTS',`RUN ( cover COVER_REPORT_OPTS -report codecov covers/* || true )',`')
