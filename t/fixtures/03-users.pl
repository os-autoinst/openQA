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
        api_keys => [{ key => 'LANCELOTKEY01', secret => 'MANYPEOPLEKNOW', id => 99901},]
    },
    Users => {
        id => 99903,
        openid => 'https://openid.camelot.uk/percival',
        is_operator => 1,
        is_admin => 0,
        api_keys => [
            {
                key => 'EXPIREDKEY01',
                secret => 'WHOCARESAFTERALL',
                id => 99902,
                t_expiration => DateTime->from_epoch(epoch => time-7200)
            },
            {
                key => 'PERCIVALKEY01',
                secret => 'PERCIVALSECRET01',
                id => 99903,
                t_expiration => DateTime->from_epoch(epoch => time+7200)
            },
            { key => 'PERCIVALKEY02', secret => 'PERCIVALSECRET02', id => 99904},
        ]
    }
]
# vim: set sw=4 et:
