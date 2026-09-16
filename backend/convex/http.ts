import { httpRouter } from "convex/server";
import { httpAction } from "./_generated/server";
import { components } from "./_generated/api";
import { tool } from "ai";
import { Agent } from "@convex-dev/agent";
import { convexGateway } from "@convex-dev/ai-sdk-provider";
import { instructions, requestSchema, suggestionSchema, prepareSuggestions } from "../lib/grouping";

import { classificationRequest, classificationOutput, classificationInstructions, validateClassification } from "../lib/classification";

import { openRequest, openProposal, requestInstructions, validateOpenProposal } from "../lib/requests";
const requestPlanner = new Agent(components.agent, {
  name: "Window request planner",
  languageModel: convexGateway("anthropic/claude-sonnet-4.5"),
  instructions: requestInstructions,
});
import { textRequest, textProposal, textInstructions, validateTextProposal } from "../lib/requests";
const textPlanner = new Agent(components.agent, {
  name: "Local request planner",
  languageModel: convexGateway("anthropic/claude-sonnet-4.5"), instructions: textInstructions,
});
import { matchRequest, matchOutput, matchInstructions, validateMatches } from "../lib/matching";
const windowMatcher = new Agent(components.agent, {
  name: "Window matcher", languageModel: convexGateway("google/gemini-2.5-flash-lite"), instructions: matchInstructions,
});
const router = httpRouter();
const classifier = new Agent(components.agent, {
  name: "Desktop objective classifier",
  languageModel: convexGateway("anthropic/claude-sonnet-4.5"),
  instructions: classificationInstructions,
});
const organizer = new Agent(components.agent, {
  name: "Objective organizer",
  languageModel: convexGateway("anthropic/claude-sonnet-4.5"),
  instructions,
});
const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), {
  status, headers: { "Content-Type": "application/json", "Cache-Control": "no-store" },
});
router.route({ path: "/suggest-objectives", method: "POST", handler: httpAction(async (ctx, request) => {
  // Dedicated single-user desktop backend. No deployment/provider credential goes to the Mac.
  const token = process.env.TV_DEVICE_TOKEN;
  if (!token || token.length < 32) return json({ error: "AI grouping is not configured on this deployment." }, 503);
  if (request.headers.get("Authorization") !== `Bearer ${token}`) return json({ error: "Unauthorized" }, 401);
  if (Number(request.headers.get("Content-Length") ?? 0) > 120000) return json({ error: "Too much metadata" }, 413);
  const body = await request.text();
  if (body.length > 120000) return json({ error: "Too much metadata" }, 413);
  let candidates;
  try {
    candidates = requestSchema.parse(JSON.parse(body)).candidates;
    if (new Set(candidates.map(c => c.id)).size !== candidates.length) throw new Error("Duplicate IDs");
  } catch { return json({ error: "Invalid window metadata" }, 400); }
  try {
    const result = await organizer.generateText(ctx, { userId: "desktop-owner" }, {
      tools: { suggest_objectives: tool({ description: "Submit proposed objective groups for user review. This does not change windows.", inputSchema: suggestionSchema }) },
      toolChoice: { type: "tool", toolName: "suggest_objectives" },
      prompt: JSON.stringify({ candidates }),
      maxOutputTokens: 5000,
      abortSignal: AbortSignal.timeout(60000),
    }, { storageOptions: { saveMessages: "none" } });
    return json(prepareSuggestions(result.toolCalls.find(call => call.toolName === "suggest_objectives")?.input, candidates.map(c => c.id)));
  } catch (error) {
    console.error("Objective grouping failed:", error instanceof Error ? error.message : "Unknown error");
    return json({ error: "AI grouping failed. Check gateway availability in your Convex deployment and try again." }, 502);
  }
}) });
router.route({ path: "/classify-objectives", method: "POST", handler: httpAction(async (ctx, request) => {
  const token = process.env.TV_DEVICE_TOKEN;
  if (!token || token.length < 32) return json({ error: "AI grouping is not configured on this deployment." }, 503);
  if (request.headers.get("Authorization") !== `Bearer ${token}`) return json({ error: "Unauthorized" }, 401);
  if (Number(request.headers.get("Content-Length") ?? 0) > 2000000) return json({ error: "Grouping metadata exceeds 2 MB." }, 413);
  const body = await request.text();
  if (new TextEncoder().encode(body).length > 2000000) return json({ error: "Grouping metadata exceeds 2 MB." }, 413);
  let input;
  try {
    input = classificationRequest.parse(JSON.parse(body));
    const ids = new Set(input.overview.map(c => c.id));
    if (ids.size !== input.overview.length || new Set(input.candidates.map(c => c.id)).size !== input.candidates.length ||
        new Set(input.objectives.map(o => o.id)).size !== input.objectives.length || input.candidates.some(c => !ids.has(c.id))) throw new Error("Invalid IDs");
  } catch { return json({ error: "Invalid grouping metadata." }, 400); }
  const started = Date.now();
  try {
    const result = await classifier.generateText(ctx, { userId: "desktop-owner" }, {
      tools: { classify_objectives: tool({ description: "Assign this batch of windows to shared objectives for review.", inputSchema: classificationOutput }) },
      toolChoice: { type: "tool", toolName: "classify_objectives" },
      prompt: JSON.stringify(input), maxOutputTokens: 12000,
      abortSignal: AbortSignal.timeout(120000),
    }, { storageOptions: { saveMessages: "none" } });
    const output = validateClassification(input, result.toolCalls.find(call => call.toolName === "classify_objectives")?.input);
    console.info("Objective batch completed", { windows: input.candidates.length, total: input.overview.length, elapsedMs: Date.now() - started, finishReason: result.finishReason });
    return json(output);
  } catch (error) {
    // Never log model output, window metadata, or provider error bodies.
    const name = error instanceof Error ? error.name : "UnknownError";
    const timedOut = name === "TimeoutError" || name === "AbortError";
    console.error("Objective batch failed", { windows: input.candidates.length, total: input.overview.length, elapsedMs: Date.now() - started, errorType: name });
    return json({ error: timedOut ? "This batch timed out. Completed windows are saved; retry to continue." : "This batch could not be classified. Completed windows are saved; retry to continue." }, timedOut ? 504 : 502);
  }
}) });
router.route({ path: "/plan-open", method: "POST", handler: httpAction(async (ctx, request) => {
  const token = process.env.TV_DEVICE_TOKEN;
  if (!token || token.length < 32) return json({ error: "Request planning is not configured." }, 503);
  if (request.headers.get("Authorization") !== `Bearer ${token}`) return json({ error: "Unauthorized" }, 401);
  if (request.headers.has("Origin")) return json({ error: "Browser requests are not supported." }, 403);
  if (Number(request.headers.get("Content-Length") ?? 0) > 2000000) return json({ error: "Too much metadata." }, 413);
  const body = await request.text();
  if (new TextEncoder().encode(body).length > 2000000) return json({ error: "Too much metadata." }, 413);
  let input;
  try {
    input = openRequest.parse(JSON.parse(body));
    if (new Set(input.resources.map(r => r.id)).size !== input.resources.length) throw new Error("Duplicate IDs");
  } catch { return json({ error: "Invalid request." }, 400); }
  try {
    const result = await requestPlanner.generateText(ctx, { userId: "desktop-owner" }, {
      tools: { propose_open: tool({ description: "Propose existing targets for local review. Does not execute anything.", inputSchema: openProposal }) },
      toolChoice: { type: "tool", toolName: "propose_open" },
      prompt: JSON.stringify(input), maxOutputTokens: 1800, abortSignal: AbortSignal.timeout(60000),
    }, { storageOptions: { saveMessages: "none" } });
    return json(validateOpenProposal(input, result.toolCalls.find(call => call.toolName === "propose_open")?.input));
  } catch {
    return json({ error: "Couldn’t interpret the request. Try again." }, 502);
  }
}) });
router.route({ path: "/plan-request", method: "POST", handler: httpAction(async (ctx, request) => {
  const token = process.env.TV_DEVICE_TOKEN;
  if (!token || token.length < 32) return json({ error: "Request planning is not configured." }, 503);
  if (request.headers.get("Authorization") !== `Bearer ${token}`) return json({ error: "Unauthorized" }, 401);
  if (request.headers.has("Origin")) return json({ error: "Browser requests are not supported." }, 403);
  if (Number(request.headers.get("Content-Length") ?? 0) > 2000000) return json({ error: "Too much metadata." }, 413);
  const body = await request.text();
  if (new TextEncoder().encode(body).length > 2000000) return json({ error: "Too much metadata." }, 413);
  let input;
  try {
    input = textRequest.parse(JSON.parse(body));
    if (new Set(input.resources.map(r => r.id)).size !== input.resources.length) throw new Error("Duplicate IDs");
  } catch { return json({ error: "Invalid request." }, 400); }
  try {
    const result = await textPlanner.generateText(ctx, { userId: "desktop-owner" }, {
      tools: { propose_open: tool({ description: "Propose existing targets for local review. Does not execute anything.", inputSchema: textProposal }) },
      toolChoice: { type: "tool", toolName: "propose_open" },
      prompt: JSON.stringify(input), maxOutputTokens: 1800, abortSignal: AbortSignal.timeout(60000),
    }, { storageOptions: { saveMessages: "none" } });
    return json(validateTextProposal(input, result.toolCalls.find(call => call.toolName === "propose_open")?.input));
  } catch {
    return json({ error: "Couldn’t interpret the request. Try again." }, 502);
  }
}) });
router.route({ path: "/match-windows", method: "POST", handler: httpAction(async (ctx, request) => {
  const token = process.env.TV_DEVICE_TOKEN;
  if (!token || token.length < 32) return json({ error: "Matching is not configured." }, 503);
  if (request.headers.get("Authorization") !== `Bearer ${token}`) return json({ error: "Unauthorized" }, 401);
  if (request.headers.has("Origin")) return json({ error: "Browser requests are not supported." }, 403);
  if (Number(request.headers.get("Content-Length") ?? 0) > 2000000) return json({ error: "Too much metadata." }, 413);
  const body = await request.text();
  if (new TextEncoder().encode(body).length > 2000000) return json({ error: "Too much metadata." }, 413);
  let input;
  try {
    input = matchRequest.parse(JSON.parse(body));
    if (new Set(input.windows.map(w => w.id)).size !== input.windows.length) throw new Error("Duplicate IDs");
  } catch { return json({ error: "Invalid search metadata." }, 400); }
  const started = Date.now();
  try {
    const result = await windowMatcher.generateText(ctx, { userId: "desktop-owner" }, {
      tools: { matches: tool({ description: "Return ranked matching window IDs.", inputSchema: matchOutput }) },
      toolChoice: { type: "tool", toolName: "matches" }, prompt: JSON.stringify(input),
      maxOutputTokens: 300, abortSignal: AbortSignal.timeout(10000),
    }, { storageOptions: { saveMessages: "none" } });
    return json({ ...validateMatches(input, result.toolCalls.find(call => call.toolName === "matches")?.input), elapsedMs: Date.now() - started });
  } catch { return json({ error: "AI matching is unavailable; local search still works." }, 502); }
}) });
export default router;
