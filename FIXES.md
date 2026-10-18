# Completion data loss fix

This fork fixes a reproducible cause of SharpLab issues
[#1316](https://github.com/ashmind/SharpLab/issues/1316),
[#1352](https://github.com/ashmind/SharpLab/issues/1352) and
[#1358](https://github.com/ashmind/SharpLab/issues/1358).

## Reproduction and cause

On 2026-10-18, a WebSocket session against the upstream service with this input
and the cursor after `Con` returned a completion list containing `Console`:

```csharp
using System;
class C { void M() { Con } }
```

The completion span was `{ "start": 36, "length": 3 }`. Selecting `Console`
returned this destructive change:

```json
{"type":"changes","reason":"completion","changes":[{"start":0,"length":39,"text":""}]}
```

MirrorSharp expanded an empty provider result at `(0, 0)` to the cursor. This
turned a failed completion into deletion of the entire prefix. Roslyn's completion
service can return this empty result when a provider fails; the specific provider
failure in the upstream deployment was not diagnosed here.

The patched handler recognizes that sentinel before expanding the range, uses
the advertised completion item's display text as a basic fallback, and replaces
only the active completion span and any additional text typed within that word.
Ordinary provider edits, including qualified names and document-wide edits, keep
their original replacement text. The fallback does not reproduce complex provider
features such as adding imports or snippets when that provider has failed.

The server references the `mirrorsharp-codemirror-6-preview` submodule. Its URL now
points to this account's MirrorSharp fork and its commit is pinned, so recursive
clones receive the actual fix. The stable front-end submodule is unchanged.

## Validation

```powershell
git submodule update --init --recursive
dotnet restore tests/CompletionRegression/CompletionRegression.csproj --locked-mode
dotnet test tests/CompletionRegression/CompletionRegression.csproj --no-restore
```

Eight focused tests link the exact normalization source compiled into the server.
Five failed against the original algorithm; all eight pass with the fix. They
cover prefix/suffix preservation, CRLF, Chinese and emoji, empty documents,
continued typing, qualified provider text and genuine deletion edits. They were
run targeting .NET 9 using the installed .NET 10 runtime with
`DOTNET_ROLL_FORWARD=Major`; CI uses the .NET 9 SDK/runtime directly.

`global.json` permits newer major SDKs while the application still targets .NET 9.
The full legacy application and browser interaction suite are separate from
these focused regression tests. This change does not claim to fix every possible
editor synchronization or completion race.

## Local startup (verified on Windows, 2026-10-18)

```powershell
cd "D:\Project\Tool Project\SharpLab"
.\sl.bat setup  # first checkout only
.\sl.bat run
```

Open http://localhost:44100/. Keep the terminal running; Ctrl+C stops only the
services started by that command. Logs are saved in the ignored `!local` folder.
After building once, `sl run -SkipBuild` starts the existing binaries and assets.
The runner reports an occupied port instead of terminating an existing service.

The startup fixes include npm 12-compatible local dependency paths/lockfile,
HTTPS for the pinned Git dependency, and project-specific permission to install
that direct Git dependency and the required sharp/esbuild native components.
The runner starts the actual web server, asset server, Azurite and sandbox manager
directly, without Tye. It also installs the sandbox's existing read/execute ACL.

Validation completed locally:

- Full frontend build, TypeScript checking and lint passed.
- WebApp.Server and Container.Manager built with zero warnings/errors.
- Browser accepted `Console` with Tab and `WriteLine` with `(` while retaining
  the preceding code and comment.
- Real HTTP and WebSocket checks verified prefix/suffix preservation, C#
  compilation, and `Console.WriteLine` execution in the sandbox.
- npm 12 accepted `npm ci --dry-run` against the repaired lockfile.

With the website running, repeat the HTTP/WebSocket checks using Node.js 22+:

```powershell
node tests/local-smoke.cjs
```

## Hosting

No website deployment is configured for this fork. GitHub Actions runs regression
checks only. The upstream Azure deployment workflows require the upstream owner's
infrastructure and credentials; they are disabled in this fork.
