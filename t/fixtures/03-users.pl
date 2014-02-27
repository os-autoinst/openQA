[
  Users => {
    id => 99901,
    openid => 'https://openid.camelot.uk/arthur',
    is_operator => 1,
    is_admin => 1,
  },
  Users => {
    id => 99902,
    openid => 'https://openid.camelot.uk/lancelot',
    is_operator => 0,
    is_admin => 0,
    api_keys => [
        { key => 'LANCELOTKEY01', secret => 'MANYPEOPLEKNOW'},
    ]
  },
  Users => {
    id => 99903,
    openid => 'https://openid.camelot.uk/percival',
    is_operator => 1,
    is_admin => 0,
    api_keys => [
        { key => 'EXPIREDKEY01', secret => 'WHOCARESAFTERALL',
            t_expiration => DateTime->from_epoch(epoch => time-7200) },
        { key => 'PERCIVALKEY01', secret => 'PERCIVALSECRET01',
            t_expiration => DateTime->from_epoch(epoch => time+7200) },
        { key => 'PERCIVALKEY02', secret => 'PERCIVALSECRET02' },
    ]
  }
]
