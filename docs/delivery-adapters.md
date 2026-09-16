# Delivery adapters

Experimental builds include a `DeliveryAdapter` protocol and registry. The native request UI and planner consume the registry's `DeliveryCapability` descriptors; they do not select an app by a hardcoded app-name branch. Current capability: `shareLink` (one exact HTTP(S) URL).

Built-in implementations:

- Messages: resolve an iMessage participant, then bind its participant ID, account ID, name, and handle.
- Slack: use the open desktop app and active workspace, resolve one sidebar destination, navigate to obtain its stable workspace/conversation route, and identify the main composer. No token or browser extension is used. Ambiguous names, missing destinations, existing drafts, and changed routes stop the action. Threads and message lists are not traversed by the adapter. Native sending depends on Slack's Accessibility controls and supported labels.

The local broker owns Touch ID approval, expiration, source revision checks, one-shot dispatch, and audit. Adapters receive a concrete `LinkDeliveryPreview`; they cannot create an approval or grant. The model can only propose an installed adapter ID. Destination details and execution stay local.

## Contributing an adapter

Implement `DeliveryAdapter` with a descriptor, recipient discovery, and a typed send operation; register it in `DeliveryAdapters.shared`. Use stable destination identity and revalidate it at execution. Preserve existing drafts. Provide tests for destination changes, ambiguous recipients, unsupported inputs, and uncertain send outcomes. Never automatically retry an unconfirmed send.

Adapters are currently trusted, compiled-in Swift code reviewed with the application. This is not a sandbox for third-party code, a downloadable plugin loader, or a community marketplace. A new capability beyond `shareLink` requires an explicit typed action, preview, broker policy, and tests; an adapter cannot declare arbitrary shell commands as a capability.

## Local composition

The request UI composes typed Swift operations in `Access/IntentTools.swift`:

- `ResourceTools.search` produces validated resource matches and a typed intent from the planner. `getLink` resolves a current resource reference to an exact HTTP(S) link.
- `RecipientTools.search` queries registered adapters and returns matches plus provider-specific lookup failures. Cross-app matches remain distinct; an explicit adapter never falls back to another provider. Cancelling stops further discovery.
- `ActionTools.prepareMessage` binds a source revision, URL, recipient, and adapter into an immutable `PreparedLocalAction`. `prepareOpen` binds a resource to an open action. Preparation does not send or open the source.
- `ActionTools.execute` asks the native host to approve that exact action inside the broker's freshness checks, then dispatches it. Sending retains the broker's one-shot and audit guarantees. Approval is not a reusable Boolean or external credential.

These are local application operations, not additional HTTP endpoints or model-executable send tools. `IntentPlanner.swift` handles model transport separately from UI state and adapter execution. Slack navigation needed to resolve a recipient stays inside its adapter and may foreground that conversation during discovery.
