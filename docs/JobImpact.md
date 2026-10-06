<a id="jobimpact"></a>

# Job Impact Assessment

openQA provides an estimated impact assessment for job executions, covering
energy consumption (kWh), carbon footprint (g CO₂e), and financial cost (€).
The primary goal is **FinOps-style showback**: making resource utilization and
environmental cost visible to test reviewers and administrators to encourage
mindful test reruns and early investigations instead of blind retriggering.

## Terminology and Standards

The methodology follows the principles of **Life Cycle Impact Assessment (LCIA)**
defined in ISO 14040 and ISO 14044:

- **Functional Unit**: A single completed openQA job execution.
- **Impact Categories**:
  - **Energy**: Total electricity consumed (`kWh`).
  - **Operational Carbon**: Greenhouse gas emissions from electricity generation
    using grid carbon intensity (`g CO₂e`), based on the Green Software Foundation
    Software Carbon Intensity (SCI) standard (ISO/IEC 21031).
  - **Embodied Carbon**: Amortized greenhouse gas emissions from hardware
    manufacturing and disposal per slot-hour (`g CO₂e`).
  - **Monetary Cost**: Combined energy and amortized hardware costs (`€` or
    configured currency).

## Calculation Model

The model is adapted from the Cloud Carbon Footprint (CCF) methodology and the
Green Software Foundation SCI equation:

```
Energy (kWh) = (Power (W) × Hours × PUE) / 1000
Carbon (g CO₂e) = (Energy × grid_g_per_kwh) + (embodied_g_per_slot_hour × Hours)
Cost (€) = (Energy × eur_per_kwh) + (hw_eur_per_slot_hour × Hours)
```

### Power Model

Power consumption in Watts is calculated through either:

1. **Fixed slot power**: If `slot_power_w` is configured (recommended for
   bare-metal workers, s390x LPARs, or measured hypervisors), that value is
   used directly:

   ```
   Power (W) = slot_power_w
   ```

2. **Component model**: For virtualized workers, power scales with assigned
   virtual resources:

   ```
   Power (W) = slot_base_w + (vCPUs × cpu_w) + (RAM_GB × mem_w)
   ```

   - `vCPUs`: Value of the job setting `QEMUCPUS` (defaults to `default_vcpus`, 1).
   - `RAM_GB`: Value of `QEMURAM` in MiB divided by 1024 (defaults to `default_ram_mb`, 1024 MiB).

### Default Parameters

The built-in default values reflect typical European data center conditions and
commodity server hardware:

| Parameter                     | Default | Description                                                |
| ----------------------------- | ------- | ---------------------------------------------------------- |
| `slot_base_w`                 | `20`    | Base idle power allocated to a worker slot (W)             |
| `cpu_w`                       | `10`    | Active CPU power per allocated vCPU (W)                    |
| `mem_w`                       | `0.392` | Active memory power per GiB RAM (W, from CCF)              |
| `pue`                         | `1.5`   | Power Usage Effectiveness of data center infrastructure    |
| `grid_g_per_kwh`              | `300`   | Grid carbon intensity (g CO₂e/kWh)                         |
| `eur_per_kwh`                 | `0.20`  | Electricity price per kWh (€)                              |
| `hw_eur_per_slot_hour`        | `0.01`  | Amortized hardware acquisition cost per slot-hour (€)      |
| `embodied_g_per_slot_hour`    | `1.0`   | Amortized embodied manufacturing emissions (g CO₂e/slot-h) |
| `default_vcpus`               | `1`     | Fallback vCPUs if `QEMUCPUS` is unset                      |
| `default_ram_mb`              | `1024`  | Fallback RAM in MiB if `QEMURAM` is unset                  |
| `history_runs`                | `10`    | Historical job runs sampled for restart estimates          |
| `allow_job_setting_overrides` | `0`     | Disallows per-job manipulation of cost factors             |

## Factor Resolution Precedence

Factors are resolved at job completion using the following precedence (highest
priority first):

1. **Job settings**: `JOB_IMPACT_*` (only if `allow_job_setting_overrides = 1` in configuration).
2. **Worker properties**: `JOB_IMPACT_*` reported dynamically by worker hosts in `workers.ini`.
3. **Class-specific configuration**: `[job_impact:<WORKER_CLASS>]` in `openqa.ini`.
4. **Global configuration**: `[job_impact]` section in `openqa.ini`.
5. **System defaults**: Built into `OpenQA::Setup`.

## Configuration Examples

### openqa.ini

```ini
[job_impact]
# Enable calculation and UI display (default: 1)
enabled = 1

# Currency symbol/code for display (default: EUR)
currency = EUR

# Electricity price in EUR per kWh
eur_per_kwh = 0.22

# Carbon intensity of local grid (g CO2e per kWh)
grid_g_per_kwh = 280

# Overrides for specific worker classes
[job_impact:qemu_ppc64le]
slot_base_w = 40
cpu_w = 15

[job_impact:bare_metal_ipmi]
# Fixed power measurement for bare-metal systems
slot_power_w = 250
hw_eur_per_slot_hour = 0.05
```

### Restart Confirmation Thresholds

Administrators can configure optional thresholds in `openqa.ini` under `[job_impact]`
to present a confirmation nudge in the web UI before expensive or repeated manual restarts:

- `confirm_restart_above_cost`: Threshold in configured currency (e.g. `1.50`).
- `confirm_restart_above_carbon_g`: Threshold in g CO₂e (e.g. `500`).
- `confirm_restart_after_manual_restarts`: Number of prior manual restart attempts (e.g. `2`).

These thresholds act as an informational nudge in the web UI. API, CLI, and automated
triggers remain unblocked.

### workers.ini

Workers can advertise specific power parameters based on local host hardware:

```ini
[global]
JOB_IMPACT_SLOT_POWER_W = 120

[class:heavy_storage]
JOB_IMPACT_SLOT_BASE_W = 35
```

## Calibration and Accuracy Disclaimer

**Estimates are approximations**: Model estimates may diverge from physical
measurements by 2× to 3× depending on CPU microarchitecture, server load,
chassis density, and local power supply efficiency.

For higher accuracy:

1. Measure worker host power using IPMI, BMC, or RAPL (Running Average Power Limit).
2. Divide average total server power draw by the number of concurrent worker slots.
3. Configure the measured value as `slot_power_w` in `workers.ini` or `openqa.ini`.

## Snapshot Semantics and No Backfill

- **Immutable Snapshots**: When a job finishes, its calculated impact and the
  resolved factor snapshot are stored immutably. Modifying configuration factors
  later does not retroactively change existing records.
- **No Backfill**: Past jobs finished before enabling or upgrading the feature
  are not retroactively populated.

## InfluxDB and Grafana Monitoring

When `[job_impact] enabled = 1`, openQA exports job impact metrics under the
existing `/admin/influxdb/jobs` endpoint.

### Measurement Schema: `openqa_job_impact`

- **Tags**:
  - `url`: Host base URL.
  - `group`: Job group name (or `No Group`).
  - `origin`: Restart origin (`first_run`, `user`, `retry`, `auto_clone`, `system`).
- **Fields**:
  - `jobs`: Completed job count within rolling window (integer, `i`).
  - `seconds`: Total runtime in seconds (integer, `i`).
  - `energy_kwh`: Total estimated electricity consumption in kWh (float).
  - `carbon_g`: Total estimated emissions in g CO₂e (float).
  - `cost_total`: Total estimated cost in configured currency (float).

### Sample InfluxQL Query for Grafana

```sql
SELECT sum("cost_total") FROM "openqa_job_impact" WHERE $timeFilter GROUP BY "group", "origin"
```
