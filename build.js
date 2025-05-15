const { execSync } = require('child_process');
const fs = require('fs');

// Ensure dist directory exists
if (!fs.existsSync('dist')) {
    fs.mkdirSync('dist');
}

// Compile main.js and cleanup.js
execSync('ncc build main.js -o dist/main', { stdio: 'inherit' });
execSync('ncc build cleanup.js -o dist/cleanup', { stdio: 'inherit' });

// Rename the compiled files
fs.renameSync('dist/main/index.js', 'dist/main.js');
fs.renameSync('dist/cleanup/index.js', 'dist/cleanup.js');

// Clean up temporary directories
fs.rmSync('dist/main', { recursive: true, force: true });
fs.rmSync('dist/cleanup', { recursive: true, force: true }); 