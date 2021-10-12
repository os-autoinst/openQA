{
    JobGroups => [
        {
            group_name => "openSUSE Leap 42.3 Updates",
            template => "scenarios: {}\nproducts: {}\n",
        },
    ],
    JobTemplates => [],
    Machines => [
        {
            backend => "qemu",
            name => "32bit",
            settings => [],
        },
        {
            backend => "qemu",
            name => "64bit",
            settings => [],
        },
    ],
    Products => [
        {
            arch => "x86_64",
            distri => "opensuse",
            flavor => "DVD",
            settings => [],
            version => 42.2,
        },
    ],
    TestSuites => [
        {
            name => "uefi",
            settings =>
              [{key => "DESKTOP", value => "kde"}, {key => "INSTALLONLY", value => 1}, {key => "UEFI", value => 1},],
        },
    ],
}
