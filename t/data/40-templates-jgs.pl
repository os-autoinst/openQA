{
    JobGroups => [
        {
            group_name => 'opensuse',
            template =>
"defaults:\n  i586:\n    machine: 64bit\n    priority: 50\nproducts:\n  opensuse-13.1-DVD-i586:\n    distri: opensuse\n    flavor: DVD\n    version: \'13.1\'\nscenarios:\n  i586:\n    opensuse-13.1-DVD-i586:\n    - textmode:\n        machine: 32bit\n        priority: 40\n    - textmode:\n        machine: 64bit\n        priority: 40\n    - advanced_kde:\n        description: such advanced very test\n        priority: 40\n        settings:\n          ADVANCED: \'1\'\n          DESKTOP: advanced_kde",
        },
    ],
    JobTemplates => [],
    Machines => [
        {
            backend => 'qemu',
            name => '32bit',
            settings => [],
        },
        {
            backend => 'qemu',
            name => '64bit',
            settings => [],
        },
    ],
    Products => [
        {
            arch => 'i586',
            distri => 'opensuse',
            flavor => 'DVD',
            settings => [],
            version => 13.1,
        },
    ],
    TestSuites => [
        {
            name => 'textmode',
            settings => [{key => 'DESKTOP', value => 'textmode'}, {key => 'VIDEOMODE', value => 'text'},],
        },
        {
            name => 'advanced_kde',
            description => 'See kde for simple test',
            settings => [
                {key => 'DESKTOP', value => 'kde'},
                {key => 'START_AFTER_TEST', value => 'kde,textmode'},
                {key => 'PUBLISH_HDD_1', value => '%DISTRI%-%VERSION%-%ARCH%-%DESKTOP%-%QEMUCPU%.qcow2'}
            ],
        },
    ],
}
