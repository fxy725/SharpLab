// Run against `sl run`. Requires Node.js 22 or newer (built-in WebSocket).
const assert = require('node:assert/strict');

async function connect() {
    const socket = new WebSocket('ws://localhost:44100/mirrorsharp');
    const messages = [];
    const listeners = new Set();
    socket.addEventListener('message', event => {
        const message = JSON.parse(event.data);
        messages.push(message);
        for (const listener of listeners) listener();
    });
    await new Promise((resolve, reject) => {
        socket.addEventListener('open', resolve, { once: true });
        socket.addEventListener('error', reject, { once: true });
    });
    return {
        send: message => socket.send(message),
        close: () => socket.close(),
        wait: predicate => new Promise((resolve, reject) => {
            const timeout = setTimeout(() => {
                listeners.delete(check);
                reject(new Error('Timed out waiting for the local server.'));
            }, 20000);
            function check() {
                const error = messages.find(m => m.type === 'error');
                if (error) {
                    clearTimeout(timeout);
                    listeners.delete(check);
                    reject(new Error(error.message));
                    return;
                }
                const index = messages.findIndex(predicate);
                if (index < 0) return;
                clearTimeout(timeout);
                listeners.delete(check);
                resolve(messages.splice(index, 1)[0]);
            }
            listeners.add(check);
            check();
        })
    };
}

async function main() {
    for (const url of ['http://localhost:44100/', 'http://localhost:44200/latest', 'http://localhost:44400/status']) {
        const response = await fetch(url, { signal: AbortSignal.timeout(10000) });
        assert.equal(response.status, 200, url);
        console.log('PASS HTTP', url);
    }

    const completion = await connect();
    try {
        const source = 'using System;\r\n// Preserve this prefix.\r\nclass C { void M() { Con.WriteLine("OK"); } }';
        const start = source.indexOf('Con.WriteLine');
        completion.send('Ox-optimize=debug,x-target=C#,x-no-cache=true,language=C#');
        completion.send(`R0:0:${start + 3}::${source}`);
        completion.send('SF');
        const list = await completion.wait(m => m.type === 'completions');
        const index = list.completions.findIndex(item => item.displayText === 'Console');
        assert.ok(index >= 0, 'Console must be offered');
        completion.send('S' + index);
        const message = await completion.wait(m => m.type === 'changes' && m.reason === 'completion');
        let updated = source;
        let offset = 0;
        for (const change of message.changes) {
            const position = change.start + offset;
            updated = updated.slice(0, position) + change.text + updated.slice(position + change.length);
            completion.send(`R${position}:${change.length}:${start + 7}:completion:${change.text}`);
            offset += change.text.length - change.length;
        }
        assert.equal(updated, source.replace('Con.WriteLine', 'Console.WriteLine'));
        completion.send('U');
        const result = await completion.wait(m => m.type === 'slowUpdate');
        assert.equal(result.diagnostics.filter(d => d.severity === 'error').length, 0);
        assert.ok(JSON.stringify(result.x).includes('WriteLine'));
        console.log('PASS Console completion preserves prefix/suffix and compiles');
    }
    finally { completion.close(); }

    const run = await connect();
    try {
        const source = 'using System; Console.WriteLine("SHARPLAB_SMOKE_OK");';
        run.send('Ox-optimize=debug,x-target=Run,x-no-cache=true,language=C#');
        run.send(`R0:0:${source.length}::${source}`);
        run.send('U');
        const result = await run.wait(m => m.type === 'slowUpdate');
        assert.equal(result.diagnostics.filter(d => d.severity === 'error').length, 0);
        assert.ok(JSON.stringify(result.x).includes('SHARPLAB_SMOKE_OK'), JSON.stringify(result.x));
        console.log('PASS Run mode executes code in the local container');
    }
    finally { run.close(); }
}

main().catch(error => { console.error(error); process.exitCode = 1; });
