// Stand-in for the Messages API for tests/test-mod-injection.sh: writes each request body to <dir>/req-NNN.json and
// answers over SSE, so a test reads exactly what the model would have been sent. No credentials, no network.
//   SPAWN:<type> in a user message -> an Agent tool_use for that subagent type
//   AUTOCOMPACT  in a user message -> a Bash tool_use reporting a nearly full context
//   anything else                  -> "ok"
import fs from "node:fs";
import http from "node:http";

const dir = process.argv[2];
let n = 0;

const textOf = (m) => (typeof m.content === "string" ? m.content : m.content.map((b) => b.text ?? "").join("\n"));

function reply(body) {
  const last = body.messages?.at(-1);
  const isToolResult = Array.isArray(last?.content) && last.content.some((c) => c.type === "tool_result");
  const text = last && !isToolResult ? textOf(last) : "";
  const spawn = text.match(/SPAWN:(\S+)/);
  if (spawn) {
    return { tool: { name: "Agent", input: { subagent_type: spawn[1], description: "probe", prompt: "SUBAGENT_PROMPT" } }, input_tokens: 10 };
  }
  if (text.includes("AUTOCOMPACT")) {
    return { tool: { name: "Bash", input: { command: "true", description: "probe" } }, input_tokens: 190000 };
  }
  return { input_tokens: 10 };
}

http
  .createServer((req, res) => {
    let raw = "";
    req.on("data", (d) => (raw += d));
    req.on("end", () => {
      if (!req.url.startsWith("/v1/messages") || req.url.includes("count_tokens")) {
        res.writeHead(200, { "content-type": "application/json" });
        res.end(JSON.stringify({ input_tokens: 10, data: [] }));
        return;
      }
      n += 1;
      fs.writeFileSync(`${dir}/req-${String(n).padStart(3, "0")}.json`, raw);
      const body = JSON.parse(raw);
      const { tool, input_tokens } = reply(body);
      const usage = { input_tokens, output_tokens: 5 };
      const send = (type, data) => res.write(`event: ${type}\ndata: ${JSON.stringify({ type, ...data })}\n\n`);
      res.writeHead(200, { "content-type": "text/event-stream" });
      send("message_start", {
        message: { id: `msg_${n}`, type: "message", role: "assistant", model: body.model, content: [], stop_reason: null, stop_sequence: null, usage },
      });
      if (tool) {
        send("content_block_start", { index: 0, content_block: { type: "tool_use", id: `toolu_${n}`, name: tool.name, input: {} } });
        send("content_block_delta", { index: 0, delta: { type: "input_json_delta", partial_json: JSON.stringify(tool.input) } });
      } else {
        send("content_block_start", { index: 0, content_block: { type: "text", text: "" } });
        send("content_block_delta", { index: 0, delta: { type: "text_delta", text: "ok" } });
      }
      send("content_block_stop", { index: 0 });
      send("message_delta", { delta: { stop_reason: tool ? "tool_use" : "end_turn", stop_sequence: null }, usage });
      send("message_stop", {});
      res.end();
    });
  })
  .listen(0, "127.0.0.1", function () {
    fs.writeFileSync(`${dir}/port`, String(this.address().port));
  });
