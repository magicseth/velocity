# Local agent access

Velocity includes a local permission broker for **opening and closing catalogued resources**. The ordinary search UI still works without enabling it. This is a capability boundary for clients using Velocity's API, not an OS sandbox: a process that already has Accessibility, shell access, another app's credentials, or access to this user's files can act outside Velocity. Bearer credentials identify paired clients; they do not attest executable identity.

## Setup

1. Open **Agent Access…** from Velocity's menu-bar menu, or press **⌘,** while Velocity is focused.
2. Create a project. In **Resources**, assign specific live resources to it. Resources start private; **Block** excludes a resource from agent access.
3. In **Agents & projects**, pair an agent with that project. Pairing permits discovery of resource names and metadata in that project, not actions. Copy the credential to the intended agent. Velocity saves only its SHA-256 digest.
4. Choose **Enable local access**. The displayed endpoint is bound to `127.0.0.1` on an ephemeral port. Access is off at application launch.
5. Review requests in **Requests**. Allow once, deny, or allow opening the exact resource for one hour. Closing has no reusable grant. Revoke grants or the agent from their respective tabs.

Project names and paired identities persist locally. Resource assignments, action grants, and pending requests do not survive restart. Disappearing resources retire their IDs. Changes to a resource's title, URL, capabilities, or scope invalidate its revision and grants; observed target changes clear its assignment. This conservative behavior prevents new content from inheriting old authority.

Stopping access closes the listener, removes grants, and denies pending requests. Revocation prevents subsequent dispatch; it cannot undo an operation already dispatched to another app. Native confirmation/save dialogs are not automatically accepted.

## Protocol

Send `POST` to the displayed `/v1/access` endpoint with `Content-Type: application/json` and `Authorization: Bearer <credential>`. Store the endpoint and credential in the client environment or its secret store, not source control. There is no unauthenticated discovery, pairing, approval, or grant endpoint. Browser-origin requests are rejected.

List resources:

```json
{"operation":"resources"}
```

Returns `resources`, each containing an opaque `id`, `revision`, name (`title`), adapter/app, kind, project ID, safety setting, and available capabilities. Only resources in the authenticated client's project are returned.

Request an action using an ID and revision from that response:

```json
{
  "operation":"request",
  "resourceID":"<resource UUID>",
  "revision":"<revision UUID>",
  "action":"open",
  "nonce":"<new client-generated UUID>",
  "reason":"Bring the project documentation forward"
}
```

The only action values are `open` and `close`. Name-only destinations (Messages/Slack sidebar conversations and Claude Code project labels) are discovery-only in this API because a different destination can reuse a name; their capability set is empty. They remain navigable through the human search UI. Reusing a nonce for the same request returns its existing status without repeating execution; changing its target or action is rejected. A request expires after five minutes. Each agent can have at most 20 pending requests; the session retains at most 5,000 requests. A pending response is not permission to proceed outside Velocity.

Poll the returned request ID:

```json
{"operation":"status","requestID":"<request UUID>"}
```

Statuses: `pending`, `executing`, `succeeded`, `failed`, `denied`, `expired`. Clients can read only their own requests. `succeeded` means the native adapter accepted the operation, not that a browser finished loading or a document passed a save dialog. Errors return HTTP 403 with an `error` string. No command/script/keystroke execution, arbitrary URLs, message sending, file contents, or terminal transcript APIs are exposed.

## Storage and audit

A process-wide storage lock prevents two Velocity builds from managing the same stored identities concurrently. State is under `~/Library/Application Support/Velocity/Access/`: the directory is mode 0700; configuration and audit files are mode 0600. `audit.jsonl` records decisions, dispatch attempts, and results using resource/request/agent IDs. It excludes credentials, agent-provided reasons, document contents, and message bodies. The native Audit tab shows this session's latest 500 events; the append-only file retains previous sessions. It is not tamper-proof against this macOS user. If audit/configuration storage fails, the broker disables actions.

## Implementation boundaries

- `ResourceBroker` owns scopes, identities, grants, request lifecycle, revision checks, and auditing.
- `AccessServer` authenticates bounded local requests; it cannot assign resources or approve requests.
- `AccessView` provides native user controls for pairing, scope assignment, approval, and revocation.
- `AccessIntegration` dispatches only the supported operation on the exact resource. It does not bring objective companions forward.
- `ResourceTarget` revalidates live native handles; browser selection/close scripts check tab URL/title at the action boundary.
- Built-in adapters are trusted application code. No downloadable executable adapters are loaded.

Tests cover permission isolation, replay, expiration, revocation, changing resources, audit failure, storage, protocol rejection, and a real authenticated loopback exchange with a fake executor. They do not substitute for live verification of every application's Accessibility behavior.
