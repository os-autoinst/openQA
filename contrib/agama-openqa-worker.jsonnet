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

// Helper function to create a unique, safe alias from the device name
local raid_alias = function(dev_name) "raid-" + std.strReplace(dev_name, "/dev/", "");

// Check if we actually have enough extra disks to form a RAID 0
local has_enough_disks_for_raid = std.length(extra_disks) >= 2;

// 1. Build the OS drive config
local os_drive_config = if os_disk != null then [{
  search: os_disk,
  partitions: [{ search: {}, delete: true }, { generate: 'default' }],
}] else [];

// 2. Build the extra drives config dynamically
local extra_drives_config = std.map(
  function(disk) {
    search: disk,
    ptableType: 'gpt',
    partitions: [
      { search: {}, delete: true },
      // If we have 2+ disks, prep them for RAID. Otherwise, prep as a standard Linux partition.
      if has_enough_disks_for_raid then
        { alias: raid_alias(disk), id: 'raid' }
      else
        { id: 'linux' }
    ]
  },
  extra_disks
);

// 3. Build the mdRaids config ONLY if we have at least 2 disks
local mdraids =
  if has_enough_disks_for_raid then
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
      drives: os_drive_config + extra_drives_config,
      // If mdraids is empty, Agama will just ignore it safely
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
