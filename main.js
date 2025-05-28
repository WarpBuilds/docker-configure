const core = require('@actions/core');
const exec = require('@actions/exec');
const fs = require('fs').promises;
const path = require('path');
const { v4: uuidv4 } = require('uuid');
const os = require('os');
const { WarpBuildConfig, assignBuilders, getBuilderDetails } = require('./utils/warpbuild');

// Helper function to wait for builder details
async function waitForBuilderDetails(builderId, config, timeout, startTime) {
    while (true) {
        const currentTime = Date.now();
        const elapsed = currentTime - startTime;

        if (elapsed > timeout) {
            core.error(`ERROR: Global script timeout of ${timeout}ms exceeded after ${elapsed}ms`);
            core.error('Script execution terminated');
            throw new Error(`ERROR: Global script timeout of ${timeout}ms exceeded after ${elapsed}ms`);
        }

        let details;
        try {
            details = await getBuilderDetails(config, builderId);
        } catch (error) {
            core.warning(`Error getting builder details: ${error.message}`);
            await new Promise(resolve => setTimeout(resolve, 2000));
        }
        if (details.status === 'ready') {
            if (!details.metadata?.host) {
                throw new Error(`Builder ${builderId} is ready but host information is missing`);
            }
            return details;
        } else if (details.status === 'failed') {
            throw new Error(`Builder ${builderId} failed to initialize`);
        }

        core.info(`Builder ${builderId} status: ${details.status}. Waiting...`);
        await new Promise(resolve => setTimeout(resolve, 2000));
        
    }
}

async function setupBuildxNode(index, builderId, builderName, config, timeout, startTime, shouldSetupBuildx) {
    const details = await waitForBuilderDetails(builderId, config, timeout, startTime);

    const builderHost = details.metadata.host;
    const builderCa = details.metadata.ca;
    const builderClientCert = details.metadata.client_cert;
    const builderClientKey = details.metadata.client_key;
    let builderPlatforms = details.arch;

    // Format platforms
    if (builderPlatforms && !builderPlatforms.includes('linux/')) {
        builderPlatforms = builderPlatforms.split(',').map(p => `linux/${p.trim()}`).join(',');
    }

    // Create cert directory
    const certDir = path.join(os.homedir(), '.warpbuild', 'buildkit', builderName, builderId);
    await fs.mkdir(certDir, { recursive: true });

    // Write certificates
    await fs.writeFile(path.join(certDir, 'ca.pem'), builderCa);
    await fs.writeFile(path.join(certDir, 'cert.pem'), builderClientCert);
    await fs.writeFile(path.join(certDir, 'key.pem'), builderClientKey);

    // Setup buildx if required
    if (shouldSetupBuildx) {
        const baseCmd = [
            'buildx', 'create',
            '--name', builderName,
            '--node', builderId,
            '--driver', 'remote',
            '--driver-opt', `cacert=${path.join(certDir, 'ca.pem')}`,
            '--driver-opt', `cert=${path.join(certDir, 'cert.pem')}`,
            '--driver-opt', `key=${path.join(certDir, 'key.pem')}`,
            '--platform', builderPlatforms,
            '--use',
            `tcp://${builderHost}`
        ];

        // For nodes after the first one (index > 0), add the --append flag
        // This tells buildx to add this node to the existing builder context
        // instead of creating a new one
        // The splice(2, 0, '--append') inserts '--append' at index 2 of baseCmd array,
        // so it appears right after 'buildx create' in the command
        if (index > 0) {
            baseCmd.splice(2, 0, '--append');
        }

        await exec.exec('docker', baseCmd);
    }

    // Set outputs
    core.setOutput(`docker-builder-node-${index}-endpoint`, builderHost);
    core.setOutput(`docker-builder-node-${index}-platforms`, builderPlatforms);
    core.setOutput(`docker-builder-node-${index}-cacert`, builderCa);
    core.setOutput(`docker-builder-node-${index}-cert`, builderClientCert);
    core.setOutput(`docker-builder-node-${index}-key`, builderClientKey);
}

async function run() {
    try {
        let startTime = Date.now();
        const timeout = parseInt(core.getInput('timeout')) || 200000;
        const profileName = core.getInput('profile-name', { required: true });
        const shouldSetupBuildx = core.getInput('should-setup-buildx') !== 'false';

        // Initialize WarpBuild configuration
        const config = new WarpBuildConfig();

        // Assign builders
        const responseData = await assignBuilders(config, profileName, startTime, timeout);
        const builderName = `builder-${uuidv4()}`;

        // Save builder information for cleanup
        const buildersState = {
            builderName,
            builders: responseData.builder_instances.map(b => ({
                id: b.id,
                index: responseData.builder_instances.indexOf(b)
            }))
        };
        
        // Save state for post cleanup
        core.saveState('WARPBUILD_BUILDERS', JSON.stringify(buildersState));

        startTime = Date.now(); // Reset the start time.
        // Setup each builder node
        for (let i = 0; i < responseData.builder_instances.length; i++) {
            await setupBuildxNode(
                i,
                responseData.builder_instances[i].id,
                builderName,
                config,
                timeout,
                startTime,
                shouldSetupBuildx
            );
        }

    } catch (error) {
        core.setFailed(error.message);
    }
}

run(); 