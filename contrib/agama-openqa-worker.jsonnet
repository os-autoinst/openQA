local agama = import 'hw.libsonnet';

local disks = agama.selectByClass(agama.lshw, 'disk');
local disks_with_size = std.filter(function(d) std.objectHas(d, 'size'), disks);
local min_os_disk_size = 12 * 1024 * 1024 * 1024; 
local eligible_os_disks = std.filter(function(d) d.size >= min_os_disk_size, disks_with_size);
local sorted_eligible_disks = std.sort(eligible_os_disks, function(x) x.size);
local os_disk = if std.length(sorted_eligible_disks) > 0 then sorted_eligible_disks[0].logicalname else null;

// Extract just the logical names of the extra disks
local extra_disks = std.map(
  function(x) x.logicalname, 
  std.filter(function(d) d.logicalname != os_disk, disks_with_size)
);

// Helper function to create a unique, safe alias from the device name (e.g., "/dev/sdb" -> "raid-sdb")
local raid_alias = function(dev_name) "raid-" + std.strReplace(dev_name, "/dev/", "");

// 1. Build the OS drive config
local os_drive_config = if os_disk != null then [{
  search: os_disk,
  partitions: [{ search: '*', delete: true }, { generate: 'default' }],
}] else [];

// 2. Build the extra drives config dynamically
// Omitting 'size' tells Agama to use the maximum available space on the disk for the partition.
local extra_drives_config = std.map(
  function(disk) {
    search: disk,
    partitions: [{ search: '*', delete: true }, { alias: raid_alias(disk) }] 
  },
  extra_disks
);

// 3. Build the mdRaids config using the generated aliases
local mdraids =
  if std.length(extra_disks) > 0 then
    [{
      devices: std.map(raid_alias, extra_disks),
      level: "raid0",
      name: "openqa"
    }]
  else [];

{
  product: {
    id: 'openSUSE_Leap'
  },
  storage: {
      // Concatenate the OS drive and the dynamically generated extra drives
      drives: os_drive_config + extra_drives_config,
      mdRaids: mdraids
  },
  localization: {
      language: 'en_US.UTF-8',
      keyboard: 'us',
      timezone: 'UTC'
  },
  root: {
      password: '$6$N1uqucK//3AgkUBT$5feaxPeFHzLyHnwMyXh9MuJxZJADwv9ocB.sEBTGOToT5NUhxblkrpTNKey6MRLIlUZ1jjpE9WcPWgZuhkOsZ/',
      hashedPassword: true,
  },
  software: {
      patterns: ['kvm_server', 'kvm_tools'],
      packages: ['openssh', 'sudo', 'salt-minion', 'chrony']
  }
}
