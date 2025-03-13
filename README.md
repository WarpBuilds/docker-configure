# Docker Configure By WarpBuild

This GitHub Action enables WarpBuild's Remote Docker Builders in workflows, providing access to high-performance build nodes with multi-architecture support.

## Features

- 🚀 Fast Docker builds with WarpBuild's remote builder nodes.
- 🏗️ Multi-architecture builds (amd64, arm64) out of the box.
- 🔄 Automatic Docker BuildX integration.
- 🔐 Secure TLS authentication.
- 🌐 Works with both WarpBuild runners and non-WarpBuild runners.

## Prerequisites

- A Builder Profile in WarpBuild. See [WarpBuild Docs](https://docs.warpbuild.com/docs/builder-profiles).
- A WarpBuild account with a valid API key if using a non-WarpBuild runner.

## Usage

### Usage with WarpBuild Runners

```yaml
jobs:
  build:
    runs-on: warp-ubuntu-latest-x64-4x
    steps:
      - uses: actions/checkout@v3

      - name: Configure WarpBuild Docker Builders
        uses: Warpbuilds/docker-configure@v1
        with:
          profile-name: "super-fast-builder"

      - name: Build and push
        uses: docker/build-push-action@v4
        with:
          context: .
          push: true
          tags: user/app:latest
```

### Usage with Non-WarpBuild Runners

When using non-WarpBuild runners, you need to provide an API key:

```yaml
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3

      - name: Configure WarpBuild Docker Builders
        uses: Warpbuilds/docker-configure@v1
        with:
          api-key: ${{ secrets.WARPBUILD_API_KEY }}
          profile-name: "super-fast-builder"

      - name: Build and push
        uses: docker/build-push-action@v4
        with:
          context: .
          platforms: linux/amd64,linux/arm64
          push: true
          tags: user/app:latest
```

## Inputs

| Name                  | Description                                              | Required                                | Default              |
| --------------------- | -------------------------------------------------------- | --------------------------------------- | -------------------- |
| `api-key`             | WarpBuild API key for authentication                     | No (required for non-WarpBuild runners) | N/A                  |
| `profile-name`        | The builder profile to use                               | Yes                                     | N/A                  |
| `should-setup-buildx` | Whether to automatically configure Docker BuildX         | No                                      | `true`               |
| `timeout`             | Timeout in milliseconds to wait for builders to be ready | No                                      | `120000` (2 minutes) |

## Outputs

### Builder Information

| Name                              | Description                                                    |
| --------------------------------- | -------------------------------------------------------------- |
| `docker-builder-node-0-endpoint`  | Endpoint URL for the first builder node                        |
| `docker-builder-node-0-platforms` | Supported platforms for the first builder node                 |
| `docker-builder-node-0-cacert`    | CA certificate for the first builder node                      |
| `docker-builder-node-0-cert`      | Client certificate for the first builder node                  |
| `docker-builder-node-0-key`       | Client key for the first builder node                          |
| `docker-builder-node-1-endpoint`  | Endpoint URL for the second builder node (if available)        |
| `docker-builder-node-1-platforms` | Supported platforms for the second builder node (if available) |
| `docker-builder-node-1-cacert`    | CA certificate for the second builder node (if available)      |
| `docker-builder-node-1-cert`      | Client certificate for the second builder node (if available)  |
| `docker-builder-node-1-key`       | Client key for the second builder node (if available)          |

## Troubleshooting

### Common Issues

1. **Connection Timeouts**: If you experience timeouts connecting to builder nodes, try increasing the `timeout` parameter.

2. **API Key Authentication**: Ensure your API key has the necessary permissions and is correctly stored in your repository secrets.

3. **Build Failures**: When builds fail, check the builder node logs for more information. The action outputs detailed error messages to help diagnose issues.

4. **Platform Availability**: Not all profiles support all architectures. Check your profile's capabilities if you encounter platform-related errors.

## Support

For support, contact WarpBuild at [support@warpbuild.com](mailto:support@warpbuild.com) or visit [WarpBuild](https://app.warpbuild.com).
