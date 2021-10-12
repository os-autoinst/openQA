use strict;
use warnings;

[
    Users => {
        id => 99901,
        username => 'arthur',
        email => 'arthur@example.com',
        fullname => 'King Arthur',
        nickname => 'artie',
        is_operator => 1,
        is_admin => 1,
        api_keys => [{key => 'ARTHURKEY01', secret => 'EXCALIBUR'},],
        feature_version => 0,
    },
    Users => {
        id => 99902,
        # keep url to test openid compatibility
        username => 'https://openid.camelot.uk/lancelot',
        email => 'lancelot@example.com',
        fullname => 'Lancelot du Lac',
        nickname => 'lance',
        is_operator => 0,
        is_admin => 0,
        api_keys => [{key => 'LANCELOTKEY01', secret => 'MANYPEOPLEKNOW'},],
        feature_version => 0,
    },
    Users => {
        id => 99903,
        username => 'percival',
        email => 'percival@example.com',
        fullname => 'Percival',
        nickname => 'perci',
        is_operator => 1,
        is_admin => 0,
        feature_version => 0,
        api_keys => [
            {
                key => 'EXPIREDKEY01',
                secret => 'WHOCARESAFTERALL',
                t_expiration => DateTime->from_epoch(epoch => time - 7200)
            },
            {
                key => 'PERCIVALKEY01',
                secret => 'PERCIVALSECRET01',
                t_expiration => DateTime->from_epoch(epoch => time + 7200)
            },
            {key => 'PERCIVALKEY02', secret => 'PERCIVALSECRET02'},
        ]
    },
    Users => {
        id => 99904,
        username => 'Demo',
        feature_version => 0,
    },
]
