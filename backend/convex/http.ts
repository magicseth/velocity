import { httpRouter } from "convex/server";
import { httpAction } from "./_generated/server";
import { components } from "./_generated/api";
import { tool } from "ai";
import { Agent } from "@convex-dev/agent";
import { convexGateway } from "@convex-dev/ai-sdk-provider";
import { instructions, requestSchema, suggestionSchema, prepareSuggestions } from "../lib/grouping";

const router = httpRouter();
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
export default router;
