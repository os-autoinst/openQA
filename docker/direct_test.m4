m4_dnl Comment below applies to generated file, not to this template
# This Dockfile was generated from openQA Makefile with command
`# m4 -P -D M4_TEST='M4_TEST docker/direct_test.m4
# And must be called from openQA project folder like
# docker -f docker/<thisfile> .
m4_include(docker/direct_test_cache)
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
WORKDIR /opt/openqa

COPY assets ./assets
COPY cpanfile ./
COPY .perltidyrc ./
COPY dbicdh ./dbicdh
COPY lib ./lib
COPY script ./script
COPY t/ ./t
COPY templates/ ./templates
# must retry because it uses external resourses which sporadically return 404
RUN ( ./script/generate-packed-assets ./ || ./script/generate-packed-assets ./ || ./script/generate-packed-assets ./ )
# postgres is not smart to start with root, so will use their user for testing
ENV USER postgres
ENV NORMAL_USER $USER
ENV OPENQA_USE_DEFAULTS 1
RUN chown -R $USER:$USER .
m4_ifelse(FULLSTACK,`1',`RUN chown -R $USER:$USER ../os-autoinst', `')
USER $USER
m4_divert(-1)
m4_define(`DB_PATTERN',`"(Test::Database|OpenQA::Test::Case|OpenQA::Schema|setup_database)"')
m4_define(`db_setup',
ENV TEST_PG='DBI:Pg:dbname=openqa_test;host=/opt/openqa/tpg'
RUN t/test_postgresql /opt/openqa/tpg
RUN mkdir db
ENV STARTDB='pg_ctl -D /opt/openqa/tpg -l logfile start')
m4_syscmd(`grep -q -E' DB_PATTERN M4_TEST)
m4_divert(0)
m4_ifelse(m4_sysval, `0', `db_setup',`')
m4_divert(-1)
m4_define(`foreach',`m4_ifelse(m4_eval($#>2),1,
`m4_pushdef(`$1',`$3')$2`'m4_popdef(`$1')m4_dnl
`'m4_ifelse(m4_eval($#>3),1,`$0(`$1',`$2',m4_shift(m4_shift(m4_shift($@))))')')')
m4_define(`RUNCMD',RUN prove -v Xfile
)
m4_define(`RUNDBCMD',RUN ( $STARTDB; prove -v Xfile )
)
m4_define(`RUNDBBUSCMD',RUN ( $STARTDB; bus_start; prove -v Xfile )
)
m4_define(`GREP_NO_DB_PATTERN',`grep -L -E DB_PATTERN M4_TEST | tr "\n"' ``, | head -c -1'')
m4_define(`GREP_DB_PATTERN',`grep -l -E DB_PATTERN M4_TEST | tr "\n"' ``, | head -c -1'')
m4_syscmd(test $(GREP_NO_DB_PATTERN | wc -c) -gt 3)
m4_divert(-m4_sysval)
foreach(`Xfile',`RUNCMD', m4_esyscmd(GREP_NO_DB_PATTERN))
m4_syscmd(test $(GREP_DB_PATTERN | wc -c) -gt 3)
m4_divert(-m4_sysval)
foreach(`Xfile',`m4_ifelse(FULLSTACK,1,RUNDBBUSCMD,Xfile,t/14-grutasks.t,RUNDBBUSCMD,RUNDBCMD)', m4_esyscmd(GREP_DB_PATTERN))
