# LibreChat openQA Configuration

This directory contains the necessary configuration files to run LibreChat
with a custom connection to the MCP instance which runs on openqa.opensuse.org.

## Prerequisites

- You must have a local clone of the official LibreChat repository:
  ```bash
  git clone https://github.com/danny-avila/LibreChat.git
  ```
- You must have Docker or Podman with `docker-compose` or `podman-compose` installed.

## Setup Instructions

1.  **Copy Files:**
    Copy all the files from this directory ( `docker-compose.yml`, `librechat.yaml`, and `.env.openqa`) into the root of your cloned `LibreChat` repository.
    Notice that for simplicity, we use a custom `docker-compose.yml`, rather the `docker-compose.override.yaml`. 
	
2.  **Create Environment File:**
    Create your local environment file by copying the example file:
    ```bash
    cp .env.openqa .env
    ```

3.  **Configure Environment:**
    Edit the `.env` file to add your OPENQA_API_TOKEN of a special user
    `o3-mcp-read-only`. The user has to be present on openqa.opensuse.org.
    ```
    # Example .env content
    OPENQA_API_TOKEN="o3-mcp-read-only:<key>:<secret>"
    ```

    See https://www.librechat.ai/docs/configuration for more options.

4.  **Start LibreChat:**
    The following command should start the LibreChat application stack now:
    ```bash
    # If using podman
    podman-compose up -d

    # If using docker
    docker compose up -d
    ```

5.  **Create an Initial User:** (Optional)
    Once the containers are running, you need to create a user in
    advanced. The reason is the the provided configuration disabled
    registration for now.
    ```bash
    # If using podman
    podman-compose exec api npm run create-user o3-mcp-read-only@open.qa openqa openqa <passwd> --email-verified=false
 
    # If using docker
    docker compose exec api npm run create-user o3-mcp-read-only@open.qa openqa openqa <passwd> --email-verified=false
    ```
    Notice that the password can be ignored for security reason. Without the
    password the `create-user` prompts for a new password. Follow the steps
    until the confirmation. This will create a user directly in the database.

You should now be able to access LibreChat at `http://<hostname>[:3080]` and log in with the user you just created.
