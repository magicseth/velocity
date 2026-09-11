# Objective suggestions

A private Convex HTTP endpoint uses the Convex AI Gateway and Agent component to suggest objectives from selected window metadata. It does not read terminal buffers, document contents, or page bodies. Existing groups are excluded by the Mac client. Suggestions require review before creating groups.

Configure a dedicated cloud deployment for your copy of Velocity:

```sh
npm install
npx convex dev --configure new --dev-deployment cloud --project terminal-velocity --team TEAM_SLUG --once
```

Convex AI Gateway requires an eligible paid cloud team. Set `TV_DEVICE_TOKEN` in the deployment environment to a randomly generated private device token of at least 32 characters. In Terminal Velocity → AI groups, enter that same token and `https://DEPLOYMENT.convex.site/suggest-objectives`. The Mac stores the token in Keychain. Do not use a Convex deploy key or provider API key as the device token.

After configuration, run `npm run check`, `npm test`, and `npx convex dev --once`. Smoke-test with synthetic candidate metadata before using real windows. This is a single-user integration; public distribution needs per-user authentication and usage controls.

The gateway returns proposals through a schema-defined tool call with no execution handler. The endpoint validates bounded input and rejects invented window IDs, overlapping groups, and malformed output. Titles are untrusted data. Agent message storage is disabled for these requests; selected metadata is still sent to Convex and the model provider for processing.
