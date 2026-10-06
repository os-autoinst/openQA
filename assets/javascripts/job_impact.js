function setupJobImpact() {
  const collapseEl = document.getElementById('group-impact-collapse');
  if (collapseEl) {
    collapseEl.addEventListener('show.bs.collapse', function () {
      const container = document.getElementById('group-impact-details');
      if (!container || container.dataset.loaded) return;
      const groupId = container.dataset.groupId;
      fetch(`/api/v1/job_groups/${groupId}/impact`)
        .then(response => {
          if (!response.ok) throw new Error(`HTTP ${response.status}`);
          return response.json();
        })
        .then(data => {
          container.dataset.loaded = 'true';
          const total = data.total || {};
          const byOrigin = data.by_origin || {};
          const latency = data.added_latency_hours || {};

          const totalHours = Math.round(((total.seconds || 0) / 3600) * 10) / 10;
          const totalEnergy = (total.energy_kwh || 0).toFixed(3);
          const totalCarbon =
            (total.carbon_g || 0) >= 1000
              ? ((total.carbon_g || 0) / 1000).toFixed(2) + ' kg'
              : (total.carbon_g || 0).toFixed(1) + ' g';
          const totalCost = (total.cost_total || 0).toFixed(3);

          let html = `
            <div class="table-responsive mb-0">
              <table class="table table-sm table-bordered align-middle mb-0">
                <thead class="table-light">
                  <tr>
                    <th>Execution Type</th>
                    <th class="text-end">Jobs</th>
                    <th class="text-end">Duration</th>
                    <th class="text-end">Energy</th>
                    <th class="text-end">Carbon (CO₂e)</th>
                    <th class="text-end">Cost</th>
                    <th class="text-end">Added Latency</th>
                  </tr>
                </thead>
                <tbody>
                  <tr class="table-primary fw-bold">
                    <td>Total</td>
                    <td class="text-end">${total.jobs || 0}</td>
                    <td class="text-end">${totalHours} h</td>
                    <td class="text-end">${totalEnergy} kWh</td>
                    <td class="text-end">${totalCarbon}</td>
                    <td class="text-end">≈ ${totalCost} €</td>
                    <td class="text-end">-</td>
                  </tr>
          `;

          const labels = {
            first_run: 'Initial runs',
            user: 'Manual restarts',
            retry: 'Automatic retries (RETRY)',
            auto_clone: 'Auto-clones',
            system: 'System restarts'
          };

          let hasRows = false;
          for (const [key, label] of Object.entries(labels)) {
            const row = byOrigin[key];
            if (!row || !row.jobs) continue;
            hasRows = true;
            const hours = Math.round(((row.seconds || 0) / 3600) * 10) / 10;
            const energy = (row.energy_kwh || 0).toFixed(3);
            const carbon =
              (row.carbon_g || 0) >= 1000
                ? ((row.carbon_g || 0) / 1000).toFixed(2) + ' kg'
                : (row.carbon_g || 0).toFixed(1) + ' g';
            const cost = (row.cost_total || 0).toFixed(3);
            const lat = latency[key] ? `${latency[key].toFixed(1)} h` : '-';

            html += `
              <tr>
                <td>${label}</td>
                <td class="text-end">${row.jobs}</td>
                <td class="text-end">${hours} h</td>
                <td class="text-end">${energy} kWh</td>
                <td class="text-end">${carbon}</td>
                <td class="text-end">≈ ${cost} €</td>
                <td class="text-end">${lat}</td>
              </tr>
            `;
          }

          if (!hasRows && (!total.jobs || total.jobs === 0)) {
            html += `
              <tr>
                <td colspan="7" class="text-center text-muted py-2">
                  No completed jobs with recorded impact in this group.
                </td>
              </tr>
            `;
          }

          html += `
                </tbody>
              </table>
            </div>
            <div class="mt-2 text-end">
              <small class="text-muted">
                <a href="https://open.qa/docs/#jobimpact" target="_blank" rel="noopener">
                  Methodology &amp; Standards
                </a>
              </small>
            </div>
          `;
          container.innerHTML = html;
        })
        .catch(err => {
          container.innerHTML = `<div class="alert alert-warning mb-0"><small>Failed to load impact data: ${err.message}</small></div>`;
        });
    });
  }
}

$(document).ready(function () {
  setupJobImpact();
});
