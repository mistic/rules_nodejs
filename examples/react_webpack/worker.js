/**
 * @fileoverview wrapper program around the TypeScript Watcher Compiler Host.
 *
 * It intercepts the Bazel Persistent Worker protocol, using it to
 * remote-control compiler host. It tells the compiler process to
 * consolidate file changes only when it receives a request from the worker
 * protocol.
 *
 * See https://medium.com/@mmorearty/how-to-create-a-persistent-worker-for-bazel-7738bba2cabb
 * for more background on the worker protocol.
 */
const cp = require('child_process');
const fs = require('fs');


const MNEMONIC = 'Webpack';
const worker = require('./worker');

/**
 * Timestamp of the last worker request.
 */
let workerRequestTimestamp;
let webpackCLIProcess;

function getWebpackCLIProcess(webpackCliLocation, presetWebpackPluginConfig, userWebpackConfig, extraUserArguments) {
    if (!webpackCLIProcess) {
        let webpackCmd = `${webpackCliLocation} --config ${presetWebpackPluginConfig}}`

        if (userWebpackConfig) {
            webpackCmd = `${webpackCmd} --config ${userWebpackConfig} --merge`;
        }

        if (extraUserArguments) {
            webpackCmd = `${webpackCmd} ${extraUserArguments.join(' ')}`;
        }

        webpackCLIProcess = cp.exec(webpackCmd);
    }

    return webpackCLIProcess;
}

async function emitOnce(args) {
    const watchProgram = getWebpackCLIProcess(args[0], args[1], args[2], args[3])

    watchProgram.stdout.on('data', (data) => {
        if (data.includes('WEBPACK_BAZEL_PLUGIN_COMPILATION_FINISHED')) {
            console.log('Webpack compilation succeeded');
            return true;
        }

        if (data.includes('WEBPACK_BAZEL_PLUGIN_COMPILATION_FAILED')) {
            throw new Error('Webpack compilation has failed');
        }
    });

    if (consolidateChangesCallback) {
        consolidateChangesCallback();
    }


    workerRequestTimestamp = Date.now();
    const result = await watchProgram ?.getProgram().emit(undefined, undefined, {
        isCancellationRequested: function(timestamp) {
            return timestamp !== workerRequestTimestamp;
        }.bind(null, workerRequestTimestamp),
        throwIfCancellationRequested: function(timestamp) {
            if (timestamp !== workerRequestTimestamp) {
                throw new ts.OperationCanceledException();
            }
        }.bind(null, workerRequestTimestamp),
    });

    return Boolean(result && result.diagnostics.length === 0);
}

function main() {
    if (process.argv.includes('--persistent_worker')) {
        worker.log(`Running ${MNEMONIC} as a Bazel worker`);
        worker.runWorkerLoop(emitOnce);
    } else {
        worker.log(`Running ${MNEMONIC} as a standalone process`);
        worker.log(
            `Started a new process to perform this action. Your build might be misconfigured, try	
      --strategy=${MNEMONIC}=worker`);

        let argsFilePath = process.argv.pop();
        if (argsFilePath.startsWith('@')) {
            argsFilePath = argsFilePath.slice(1)
        }
        const args = fs.readFileSync(argsFilePath).toString().split('\n');
        emitOnce(args).finally(() => cachedWatchedProgram?.close());
    }
}

if (require.main === module) {
    main();
}
