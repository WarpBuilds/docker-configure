const core = require('@actions/core');
const exec = require('@actions/exec');
const { WarpBuildConfig, teardownBuilder } = require('./utils/warpbuild');

async function cleanup() {
    try {
        // Get saved state
        const buildersStateJson = core.getState('WARPBUILD_BUILDERS');
        if (!buildersStateJson) {
            core.info('No builders state found, skipping cleanup');
            return;
        }

        const buildersState = JSON.parse(buildersStateJson);
        const { builderName, builders } = buildersState;

        core.info(`Cleaning up ${builders.length} builders...`);

        // Initialize WarpBuild configuration
        const config = new WarpBuildConfig();

        // Remove buildx instances if they exist
        try {
            await exec.exec('docker', ['buildx', 'rm', builderName]);
            core.info(`Removed buildx instance: ${builderName}`);
        } catch (error) {
            core.warning(`Failed to remove buildx instance: ${error.message}`);
        }

        // Cleanup each builder using the WarpBuild API
        for (const builder of builders) {
            try {
                let response = await teardownBuilder(config, builder.id);
                
                // Handle retry for server errors
                if (response.statusCode >= 500 && response.statusCode < 600) {
                    core.info(`Got ${response.statusCode} error, retrying teardown for builder ${builder.id} after 1 second...`);
                    await new Promise(resolve => setTimeout(resolve, 1000));
                    response = await teardownBuilder(config, builder.id);
                }

                // Check if response is valid
                if (response.statusCode >= 200 && response.statusCode < 300) {
                    core.info(`Successfully cleaned up builder ${builder.id}`);
                } else {
                    const errorMessage = response.message || response.error || 'Unknown error';
                    const errorDetails = response.rawData ? ` (Raw response: ${response.rawData})` : '';
                    const statusCode = response.statusCode || 'No status code';
                    core.warning(`Failed to cleanup builder ${builder.id}: ${statusCode} - ${errorMessage}${errorDetails}`);
                }
            } catch (error) {
                core.warning(`Error cleaning up builder ${builder.id}: ${error.message}`);
            }
        }

    } catch (error) {
        // Don't fail the build if cleanup fails
        core.warning(`Cleanup failed: ${error.message}`);
    }
}

cleanup(); 