#!/usr/bin/python3

# TODO:
#  * Add return values checks to avoid crashes/traces (no connection to openQA server, etc.)
#  * The host name of machines may not be unique

import configparser
import argparse
import json
import os
import requests
import subprocess

machine_list_idle = []
machine_list_offline = []
machine_list_busy= []
machines_to_power_on = []

jobs_worker_classes = []

config_file = os.path.join(os.environ.get("OPENQA_CONFIG", "/etc/openqa"), "openqa.ini")
config = configparser.ConfigParser()
config.read(config_file)

openqa_server = "http://localhost"

# Manage cmdline options
if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--config')
    parser.add_argument('--host')
    parser.add_argument('--osd', action='store_true')
    parser.add_argument('--o3', action='store_true')
    args = parser.parse_args()
    if args.config is not None and len(args.config):
      config_file = args.config
    if args.host is not None and len(args.host):
      openqa_server = args.host
    elif args.osd:
      openqa_server = "https://openqa.suse.de"
    elif args.o3:
      openqa_server = "https://openqa.opensuse.org"

print("Using openQA server: " + openqa_server)
print("Using config file: " + config_file)
print("")

# Scheduled/blocked jobs
scheduled_list_file = requests.get(openqa_server + '/tests/list_scheduled_ajax').content
scheduled_list_data = json.loads(scheduled_list_file)
print("Processing " + str(len(scheduled_list_data['data'])) + " job(s) in scheduled/blocked state... (will take about " + str(int(len(scheduled_list_data['data']) * 0.2)) + " seconds)")
  
# Create list of WORKER_CLASS needed
for job in scheduled_list_data['data']:
  response = requests.get(openqa_server + '/api/v1/jobs/' + str(job['id']))
  job_data = json.loads(response.content)
  jobs_worker_classes.append(job_data['job']['settings']['WORKER_CLASS'])

jobs_worker_classes = sorted(set(jobs_worker_classes))
print("Found " + str(len(jobs_worker_classes)) + " different WORKER_CLASS in scheduled jobs: " + str(jobs_worker_classes))



# Workers
workers_list_file = requests.get(openqa_server + '/api/v1/workers').content
workers_list_data = json.loads(workers_list_file)

# Create list of hosts which may need to powered up/down
for worker in workers_list_data['workers']:
  if worker['status'] in ['idle']:
    machine_list_idle.append(worker['host'])
  elif worker['status'] in ['dead']: # Looks like 'dead' means 'offline'
    machine_list_offline.append(worker['host'])
  else: # worker['status'] in ['running', 'broken']: # Looks like  'running' means 'working'
    machine_list_busy.append(worker['host'])

# Clean-up the lists
machine_list_idle = sorted(set(machine_list_idle))
machine_list_offline = sorted(set(machine_list_offline))
machine_list_busy = sorted(set(machine_list_busy))

# Remove the machine from idle/offline lists if at least 1 worker is busy
for machine in machine_list_busy:
  if machine in machine_list_idle:
    machine_list_idle.remove(machine)
  if machine in machine_list_offline:
    machine_list_offline.remove(machine)
# Remove the machine from offline list if at least 1 worker is idle
for machine in machine_list_idle:
  if machine in machine_list_offline:
    machine_list_offline.remove(machine)

# Print an overview
print(str(len(machine_list_idle)) + " workers listed fully idle: " + str(machine_list_idle))
print(str(len(machine_list_offline)) + " workers listed offline/dead: " + str(machine_list_offline))
print(str(len(machine_list_busy)) + " workers listed busy: " + str(machine_list_busy))

# Get WORKER_CLASS for each workers of each machines (idle and offline) and compare to WORKER_CLASS required by scheduled/blocked jobs
for worker in workers_list_data['workers']:
  if worker['host'] in machine_list_offline:
    for classes in jobs_worker_classes:
      if set(classes.split(',')).issubset(worker['properties']['WORKER_CLASS'].split(',')):
        machines_to_power_on.append(worker['host'])
   
  if worker['host'] in machine_list_idle:
    if worker['properties']['WORKER_CLASS'] in jobs_worker_classes:
      # Warning: scheduled (blocked?) job could be run on idle machine!
      print("Warning: scheduled (blocked?) job could be run on idle machine!")

# Power on machines which can run scheduled jobs
for machine in sorted(set(machines_to_power_on)):
  if 'power_management' in config and config['power_management'].get(machine + "_POWER_ON"):
    print("Powering ON: " + machine)
    subprocess.call(config['power_management'][machine + "_POWER_ON"])
  else:
    print("Unable to power ON '" + machine + "' - No command for that")

# Power off machines which are idle (TODO: add a threshold, e.g. idle since more than 15 minutes. Does API provide this information?)
for machine in machine_list_idle:
  if 'power_management' in config and config['power_management'].get(machine + "_POWER_OFF"):
    print("Powering OFF: " + machine)
    subprocess.call(config['power_management'][machine + "_POWER_OFF"])
  else:
    print("Unable to power OFF '" + machine + "' - No command for that")
