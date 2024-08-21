const { Octokit } = require("octokit");

//
async function checkAndRedeliverWebhooks() {
  const TOKEN = process.env.TOKEN;
  const REPO_OWNER = process.env.REPO_OWNER;
  const REPO_NAME = process.env.REPO_NAME;
  const HOOK_ID = process.env.HOOK_ID;
  const LAST_WEBOOK_REDELIVERY = process.env.LAST_WEBOOK_REDELIVERY;
  
  const WORKFLOW_REPO_NAME = process.env.WORKFLOW_REPO_NAME;
  const WORKFLOW_REPO_OWNER = process.env.WORKFLOW_REPO_OWNER;

  // Create an instance of `Octokit` using the token values that were set in the GitHub Actions workflow.
  const octokit = new Octokit({ 
    auth: TOKEN,
  });

  try {
    const lastStoredRedeliveryTime = await getVariable({
      variableName: LAST_WEBHOOK_REDELIVERY,
      repoOwner: WORKFLOW_REPO_OWNER,
      repoName: WORKFLOW_REPO_NAME,
      octokit,
    });
    // Get the last time this script ran or the current time minus 24 hours.
    const lastWebhookRedeliveryTime = lastStoredRedeliveryTime || (Date.now() - (24 * 60 * 60 * 1000)).toString();
    const newWebhookRedeliveryTime = Date.now().toString();
    const deliveries = await fetchWebhookDeliveriesSince({
      lastWebhookRedeliveryTime,
      repoOwner: REPO_OWNER,
      repoName: REPO_NAME,
      hookId: HOOK_ID,
      octokit,
    });

    // Consolidate deliveries that have the same identifier
    let deliveriesByGuid = {};
    for (const delivery of deliveries) {
      deliveriesByGuid[delivery.guid]
        ? deliveriesByGuid[delivery.guid].push(delivery)
        : (deliveriesByGuid[delivery.guid] = [delivery]);
    }
    let failedDeliveryIDs = [];
    for (const guid in deliveriesByGuid) {
      const deliveries = deliveriesByGuid[guid];
      const anySucceeded = deliveries.some(
        (delivery) => delivery.status === "OK"
      );
      if (!anySucceeded) {
        failedDeliveryIDs.push(deliveries[0].id);
      }
    }

    // Redeliver any failed deliveries.
    for (const deliveryId of failedDeliveryIDs) {
      await redeliverWebhook({
        deliveryId,
        repoOwner: REPO_OWNER,
        repoName: REPO_NAME,
        hookId: HOOK_ID,
        octokit,
      });
    }

    // Save the last time this was executed
    await updateVariable({
      variableName: LAST_WEBHOOK_REDELIVERY,
      value: newWebhookRedeliveryTime,
      variableExists: Boolean(lastStoredRedeliveryTime),
      repoOwner: WORKFLOW_REPO_OWNER,
      repoName: WORKFLOW_REPO_NAME,
      octokit,
    });

    // Log the number of redeliveries.
    console.log(
      `Redelivered ${
        failedDeliveryIDs.length
      } failed webhook deliveries out of ${
        deliveries.length
      } total deliveries since ${Date(lastWebhookRedeliveryTime)}.`
    );
  } catch (error) {
    if (error.response) {
      console.error(
        `Failed to check and redeliver webhooks: ${error.response.data.message}`
      );
    } else {
      console.error(error);
    }
    // Always throw to ensure the workflow still appears as failed
    throw(error);
  }
}

async function fetchWebhookDeliveriesSince({
  lastWebhookRedeliveryTime,
  repoOwner,
  repoName,
  hookId,
  octokit,
}) {
  const iterator = octokit.paginate.iterator(
    "GET /repos/{owner}/{repo}/hooks/{hook_id}/deliveries",
    {
      owner: repoOwner,
      repo: repoName,
      hook_id: hookId,
      per_page: 100,
      headers: {
        "x-github-api-version": "2022-11-28",
      },
    }
  );

  const deliveries = [];

  for await (const { data } of iterator) {
    const oldestDeliveryTimestamp = new Date(
      data[data.length - 1].delivered_at
    ).getTime();

    if (oldestDeliveryTimestamp < lastWebhookRedeliveryTime) {
      for (const delivery of data) {
        if (
          new Date(delivery.delivered_at).getTime() > lastWebhookRedeliveryTime
        ) {
          deliveries.push(delivery);
        } else {
          break;
        }
      }
      break;
    } else {
      deliveries.push(...data);
    }
  }

  return deliveries;
}

async function redeliverWebhook({
  deliveryId,
  repoOwner,
  repoName,
  hookId,
  octokit,
}) {
  await octokit.request(
    "POST /repos/{owner}/{repo}/hooks/{hook_id}/deliveries/{delivery_id}/attempts",
    {
      owner: repoOwner,
      repo: repoName,
      hook_id: hookId,
      delivery_id: deliveryId,
    }
  );
}

async function getVariable({ variableName, repoOwner, repoName, octokit }) {
  try {
    const {
      data: { value },
    } = await octokit.request(
      "GET /repos/{owner}/{repo}/actions/variables/{name}",
      {
        owner: repoOwner,
        repo: repoName,
        name: variableName,
      }
    );
    return value;
  } catch (error) {
    if (error.status === 404) {
      return undefined;
    } else {
      throw error;
    }
  }
}

async function updateVariable({
  variableName,
  value,
  variableExists,
  repoOwner,
  repoName,
  octokit,
}) {
  if (variableExists) {
    await octokit.request(
      "PATCH /repos/{owner}/{repo}/actions/variables/{name}",
      {
        owner: repoOwner,
        repo: repoName,
        name: variableName,
        value: value,
      }
    );
  } else {
    await octokit.request("POST /repos/{owner}/{repo}/actions/variables", {
      owner: repoOwner,
      repo: repoName,
      name: variableName,
      value: value,
    });
  }
}

(async () => {
  await checkAndRedeliverWebhooks();
})();


