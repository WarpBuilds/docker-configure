const https = require('https');
const core = require('@actions/core');

/**
 * WarpBuild API configuration and endpoints
 */
class WarpBuildConfig {
    constructor() {
        this.apiDomain = process.env.WARPBUILD_API_DOMAIN || 'https://api.warpbuild.com';
        this.isWarpbuildRunner = this.checkIsWarpbuildRunner();
        this.authHeader = this.generateAuthHeader();
    }

    /**
     * Check if running in WarpBuild runner environment
     * @returns {boolean}
     */
    checkIsWarpbuildRunner() {
        return Boolean(
            process.env.WARPBUILD_RUNNER_VERIFICATION_TOKEN && 
            process.env.WARPBUILD_RUNNER_VERIFICATION_TOKEN !== 'true'
        );
    }

    /**
     * Generate authorization header based on environment
     * @returns {string}
     * @throws {Error} if API key is missing for non-WarpBuild runners
     */
    generateAuthHeader() {
        if (this.isWarpbuildRunner) {
            return `Authorization: Bearer ${process.env.WARPBUILD_RUNNER_VERIFICATION_TOKEN}`;
        }

        const apiKey = core.getInput('api-key');
        if (!apiKey) {
            throw new Error('API key is required for non-WarpBuild runners');
        }
        return `Authorization: Bearer ${apiKey}`;
    }

    /**
     * Get builder assignment endpoint
     * @returns {string}
     */
    getAssignBuilderEndpoint() {
        return `${this.apiDomain}/api/v1/builders/assign`;
    }

    /**
     * Get builder details endpoint
     * @param {string} builderId 
     * @returns {string}
     */
    getBuilderDetailsEndpoint(builderId) {
        return `${this.apiDomain}/api/v1/builders/${builderId}/details`;
    }

    /**
     * Get builder teardown endpoint
     * @param {string} builderId 
     * @returns {string}
     */
    getBuilderTeardownEndpoint(builderId) {
        return `${this.apiDomain}/api/v1/builders/${builderId}/teardown`;
    }
}

/**
 * Makes an HTTP request to the WarpBuild API
 * @param {string} url - The full URL to make the request to
 * @param {Object} options - Request options including headers and method
 * @param {string|null} data - JSON data to send with the request
 * @returns {Promise<{statusCode: number, data: string}>}
 */
async function makeWarpBuildRequest(url, options, data = null) {
    return new Promise((resolve, reject) => {
        const req = https.request(url, options, (res) => {
            let responseData = '';
            res.on('data', (chunk) => responseData += chunk);
            res.on('end', () => {
                resolve({
                    statusCode: res.statusCode,
                    data: responseData
                });
            });
        });

        req.on('error', reject);
        if (data) req.write(data);
        req.end();
    });
}

/**
 * Assigns builders for a given profile
 * @param {WarpBuildConfig} config - WarpBuild configuration
 * @param {string} profileName - Profile name to assign builders for
 * @param {number} startTime - Starting time in milliseconds
 * @param {number} timeout - Timeout in milliseconds
 * @returns {Promise<Object>} - Parsed response with builder instances
 */
async function assignBuilders(config, profileName, startTime, timeout) {
    const [authType, authValue] = config.authHeader.split(':').map(s => s.trim());

    while (true) {
        try {
            // Check for timeout before making the request
            const currentTime = Date.now();
            const elapsedTime = currentTime - startTime;
            
            if (elapsedTime >= timeout) {
                const timeoutError = new Error(`TIMEOUT: Profile ${profileName} exceeded timeout of ${timeout}ms after ${elapsedTime}ms`);
                timeoutError.isTimeout = true;
                throw timeoutError;
            }
            
            const response = await makeWarpBuildRequest(
                config.getAssignBuilderEndpoint(),
                {
                    method: 'POST',
                    headers: {
                        'Content-Type': 'application/json',
                        [authType]: authValue
                    }
                },
                JSON.stringify({ profile_name: profileName })
            );

            const responseData = JSON.parse(response.data);
            if (response.statusCode >= 200 && response.statusCode < 300 && 
                responseData.builder_instances?.length > 0) {
                return responseData;
            }

            if (![409, 429].includes(response.statusCode) && 
                !(response.statusCode >= 500 && response.statusCode < 600)) {
                throw new Error(`API Error: ${response.statusCode} - ${JSON.stringify(responseData)}`);
            }

            // Extract error information from response
            const errorDescription = responseData.description || 'No description provided';
            core.info(`Assign builder failed: HTTP Status ${response.statusCode} - ${errorDescription}`);
            core.info('Waiting 10 seconds before next attempt...');
            
            // Check if waiting would exceed the timeout
            if (elapsedTime + 10000 >= timeout) {
                const timeoutError = new Error(`TIMEOUT: Profile ${profileName} would exceed timeout of ${timeout}ms after waiting`);
                timeoutError.isTimeout = true;
                throw timeoutError;
            }
            
            await new Promise(resolve => setTimeout(resolve, 10000));
        } catch (error) {
            // If it's already a timeout error, rethrow it
            if (error.isTimeout) {
                throw error;
            }
            
            // Check for timeout after an error
            const currentTime = Date.now();
            const elapsedTime = currentTime - startTime;
            
            if (elapsedTime >= timeout) {
                const timeoutError = new Error(`TIMEOUT: Profile ${profileName} exceeded timeout of ${timeout}ms after error: ${error.message}`);
                timeoutError.isTimeout = true;
                throw timeoutError;
            }
            
            core.warning(`Request failed: ${error.message}`);
            await new Promise(resolve => setTimeout(resolve, 10000));
        }
    }
}

/**
 * Gets builder details
 * @param {WarpBuildConfig} config - WarpBuild configuration
 * @param {string} builderId - Builder ID to get details for
 * @returns {Promise<Object>} - Builder details
 */
async function getBuilderDetails(config, builderId) {
    const [authType, authValue] = config.authHeader.split(':').map(s => s.trim());

    const response = await makeWarpBuildRequest(
        config.getBuilderDetailsEndpoint(builderId),
        {
            headers: { [authType]: authValue },
            timeout: 10000
        }
    );

    return JSON.parse(response.data);
}

/**
 * Teardown a builder
 * @param {WarpBuildConfig} config - WarpBuild configuration
 * @param {string} builderId - Builder ID to teardown
 */
async function teardownBuilder(config, builderId) {
    const [authType, authValue] = config.authHeader.split(':').map(s => s.trim());

    try {
        const response = await makeWarpBuildRequest(
            config.getBuilderTeardownEndpoint(builderId),
            {
                method: 'DELETE',
                headers: { [authType]: authValue },
                timeout: 10000
            }
        );

        let parsedData;
        try {
            parsedData = JSON.parse(response.data);
        } catch (error) {
            parsedData = { message: 'Invalid JSON response', rawData: response.data };
        }

        return {
            statusCode: response.statusCode,
            ...parsedData
        };
    } catch (error) {
        return {
            statusCode: 500,
            message: error.message || 'Request failed',
            error: true
        };
    }
}

module.exports = {
    WarpBuildConfig,
    makeWarpBuildRequest,
    assignBuilders,
    getBuilderDetails,
    teardownBuilder
}; 