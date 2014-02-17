[ Jobs => {
    id => 1,
    t_finished => undef,
    slug => 'Unicorn-42-Build666-rainbow',
    priority => 40,
    result => { name => 'none' },
    settings => [
        { key => 'DESKTOP', value => "DESKTOP"},
        { key => 'DISTRI', value => 'Unicorn'},
        { key => 'FLAVOR', value => 'pink'},
        { key => 'VERSION', value => '42'},
        { key => 'BUILD', value => '666'},
        { key => 'TEST', value => 'rainbow'},
        { key => 'ISO', value => 'whatever.iso'},
        { key => 'ISO_MAXSIZE', value => 1},
        { key => 'KVM', value => "KVM"},
        { key => 'NAME', value => '00000001-Unicorn-42-Build666-rainbow'}
    ],
    t_started => undef,
    state => { name => "scheduled"},
    worker_id => 0,
    test => 'rainbow',
    test_branch => undef
  },
  Jobs => {
      id => 2,
      t_finished => undef,
      slug => 'Unicorn-42-Build667-rainbow',
      priority => 40,
      result => { name => 'none' },
      settings => [
          { key => 'DESKTOP', value => "DESKTOP"},
          { key => 'DISTRI', value => 'Unicorn'},
          { key => 'FLAVOR', value => 'purple'},
          { key => 'VERSION', value => '42'},
          { key => 'BUILD', value => '667'},
          { key => 'TEST', value => 'rainbow'},
          { key => 'ISO', value => 'whatever.iso'},
          { key => 'ISO_MAXSIZE', value => 1},
          { key => 'KVM', value => "KVM"},
          { key => 'NAME', value => '00000001-Unicorn-42-Build667-rainbow'}
          ],
      t_started => undef,
      state => { name => "scheduled"},
      worker_id => 0,
      test => 'rainbow',
      test_branch => undef
  }
]
