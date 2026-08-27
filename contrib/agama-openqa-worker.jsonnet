local agama = import 'hw.libsonnet';

// Extract release version from /etc/os-release
local os_release = importstr '/etc/os-release';
local os_release_lines = std.split(os_release, '\n');
local version_id_lines = std.filter(function(l) std.startsWith(l, 'VERSION_ID='), os_release_lines);
local releasever = if std.length(version_id_lines) > 0 then std.strReplace(std.strReplace(version_id_lines[0], 'VERSION_ID=', ''), '"', '') else '16.0';

// --- DISK DETECTION ---
local disks = agama.selectByClass(agama.lshw, 'disk');
// Filter disks that have a size greater than 0 to ignore empty devices and exclude cdroms (/dev/sr*)
local valid_disks = std.filter(
  function(d) std.objectHas(d, 'size') && d.size > 0 && !std.startsWith(d.logicalname, '/dev/sr'),
  disks
);
local sorted_disks = std.sort(valid_disks, function(x) x.size);
local num_disks = std.length(sorted_disks);

local min_size = if num_disks > 0 then sorted_disks[0].size else 0;
local max_size = if num_disks > 0 then sorted_disks[num_disks - 1].size else 0;

local os_disks = std.filter(function(d) d.size == min_size, sorted_disks);
// Only separate openQA disks if we have a mix of disk sizes
local openqa_disks = if max_size > min_size then std.filter(function(d) d.size == max_size, sorted_disks) else [];

local os_logicalnames = std.map(function(d) d.logicalname, os_disks);
local openqa_logicalnames = std.map(function(d) d.logicalname, openqa_disks);

// --- NETWORK DETECTION ---
local network_devices = agama.selectByClass(agama.lshw, 'network');
// Filter to ensure we only grab interfaces with a logical name and ignore loopbacks
local valid_interfaces = std.filter(function(n) std.objectHas(n, 'logicalname') && n.logicalname != "lo", network_devices);
local net_ifaces = std.map(function(n) n.logicalname, valid_interfaces);

local has_multiple_ifaces = std.length(net_ifaces) >= 2;
local primary_iface = if has_multiple_ifaces then net_ifaces[0] else null;
local secondary_iface = if has_multiple_ifaces then net_ifaces[1] else null;

// Helper functions to create unique, safe aliases from the device names
local os_raid_alias = function(dev_name) "os-raid-" + std.strReplace(dev_name, "/dev/", "");
local openqa_raid_alias = function(dev_name) "oqa-raid-" + std.strReplace(dev_name, "/dev/", "");

local has_multiple_os_disks = std.length(os_logicalnames) > 1;
local has_multiple_openqa_disks = std.length(openqa_logicalnames) > 1;

// 1. Build the OS drives config dynamically
local os_drives_config = std.map(
  function(disk) {
    search: disk,
    ptableType: 'gpt',
    [if has_multiple_os_disks && disk == os_logicalnames[0] then 'alias']: 'boot_disk',
    partitions: [
      { search: '*', delete: true }
    ] + (
      // Create a dedicated /boot outside the array to prevent GRUB rescue on RAID 0
      if has_multiple_os_disks && disk == os_logicalnames[0] then
        [{ id: 'linux', size: '1 GiB', filesystem: { type: 'ext4', path: '/boot' } }]
      else
        []
    ) + [
      // If we have 2+ OS disks, prep them for RAID. Otherwise, prep as OS drive.
      if has_multiple_os_disks then
        { alias: os_raid_alias(disk), id: 'raid' }
      else
        { generate: 'default' }
    ]
  },
  os_logicalnames
);

// 2. Build the openQA data drives config dynamically
local openqa_drives_config = std.map(
  function(disk) {
    search: disk,
    ptableType: 'gpt',
    partitions: [
      { search: '*', delete: true }
    ] + [
      // If we have 2+ openQA disks, prep them for RAID. Otherwise, prep as a standard Linux partition.
      if has_multiple_openqa_disks then
        { alias: openqa_raid_alias(disk), id: 'raid' }
      else
        { id: 'linux', filesystem: { type: 'ext2', path: '/var/lib/openqa' } }
    ]
  },
  openqa_logicalnames
);

// 3. Build the mdRaids config for OS and/or openQA if needed
local os_mdraid =
  if has_multiple_os_disks then
    [{
      devices: std.map(os_raid_alias, os_logicalnames),
      level: "raid0",
      name: "openqa_os",
      ptableType: 'gpt',
      partitions: [
        { search: '*', delete: true },
        { generate: 'default' }
      ]
    }]
  else [];

local openqa_mdraid =
  if has_multiple_openqa_disks then
    [{
      devices: std.map(openqa_raid_alias, openqa_logicalnames),
      level: "raid0",
      name: "openqa_data",
      ptableType: 'gpt',
      partitions: [
        { search: '*', delete: true },
        { id: 'linux', filesystem: { type: 'ext2', path: '/var/lib/openqa' } }
      ]
    }]
  else [];

local mdraids = os_mdraid + openqa_mdraid;

{
  product: {
    id: 'openSUSE_Leap'
  },
  storage: {
      [if has_multiple_os_disks then 'boot']: {
        configure: true,
        device: 'boot_disk'
      },
      drives: os_drives_config + openqa_drives_config,
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
      packages: ['openssh', 'sudo', 'salt-minion', 'chrony'],
      extraRepositories: [
        {
            alias: "devel_openQA",
            url: "http://download.opensuse.org/repositories/devel:/openQA/" + releasever + "/",
            gpgFingerprints: ["A99A 72E3 06F2 0929 E6DE E378 5B12 1667 CBDF 5E8F"]
        },
        {
            alias: "devel_openQA_Modules",
            url: "http://download.opensuse.org/repositories/devel:/openQA:/Leap:/" + releasever + "/" + releasever + "/",
            gpgFingerprints: ["A99A 72E3 06F2 0929 E6DE E378 5B12 1667 CBDF 5E8F"]
        }
      ]
  }
} + (
  // Inject the bond configuration only if at least two interfaces exist
  if has_multiple_ifaces then {
    network: {
      connections: [
        {
          id: "Bond0",
          interface: "bond0",
          bond: {
            ports: [primary_iface, secondary_iface],
            mode: "active-backup",
            options: "primary=" + primary_iface + " miimon=100"
          }
        }
      ]
    }
  } else {}
)
