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

## Live title matching

`POST /match-windows` uses TypeSafe Jev (`jev-latest`) directly from the Convex HTTP action. Set `TYPESAFE_API_KEY` on the deployment with `npx convex env set TYPESAFE_API_KEY` (paste through stdin). The provider key stays server-side; clients continue using `TV_DEVICE_TOKEN`.

Jev evaluates each candidate's relevance independently, preserving multiple matching windows. Requests are split into batches of 64 with at most four concurrent requests; every candidate is evaluated, up to the existing 20,000-candidate / 2 MB request limits. Scores above 0.5 are ranked, returning at most 12 existing IDs. This is a search heuristic, not calibrated confidence or an authorization decision. The whole request has a ten-second deadline. Provider failures, missing answers, and invalid scores fail the request so the Mac keeps local search; partial rankings are never returned as complete.

Only the search query, app names, and titles go to TypeSafe. No terminal buffers or page bodies are read for matching. Objective grouping and request planning continue using the Convex AI Gateway. See [benchmarks](benchmarks/README.md) for reproducible synthetic checks.
