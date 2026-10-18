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

## Hosting

No website deployment is configured for this fork. GitHub Actions runs regression
checks only. The upstream Azure deployment workflows require the upstream owner's
infrastructure and credentials; they are disabled in this fork.
