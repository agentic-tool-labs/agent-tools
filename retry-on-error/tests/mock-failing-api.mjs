// Stand-in for the Messages API for tests/test-failure-e2e.sh: writes each request body to <dir>/req-NNN.json.
//   FAIL<code> in the request, and no nudge yet -> that HTTP error
//   anything else                              -> "ok" over SSE
// No credentials, no network.
import fs from "node:fs";
import http from "node:http";

const dir = process.argv[2];
const ERRORS = {
  400: { type: "invalid_request_error", message: "bad req" },
  429: { type: "rate_limit_error", message: "rate limited" },
  529: { type: "overloaded_error", message: "Overloaded" },
};
let n = 0;

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
      const code = raw.includes("The previous turn ended on an API error") ? undefined : raw.match(/FAIL(\d{3})/)?.[1];
      if (code) {
        res.writeHead(+code, { "content-type": "application/json", "retry-after": "0" });
        res.end(JSON.stringify({ type: "error", error: ERRORS[code] }));
        return;
      }
      const usage = { input_tokens: 10, output_tokens: 5 };
      const send = (type, data) => res.write(`event: ${type}\ndata: ${JSON.stringify({ type, ...data })}\n\n`);
      res.writeHead(200, { "content-type": "text/event-stream" });
      send("message_start", {
        message: { id: `msg_${n}`, type: "message", role: "assistant", model: JSON.parse(raw).model, content: [], stop_reason: null, stop_sequence: null, usage },
      });
      send("content_block_start", { index: 0, content_block: { type: "text", text: "" } });
      send("content_block_delta", { index: 0, delta: { type: "text_delta", text: "ok" } });
      send("content_block_stop", { index: 0 });
      send("message_delta", { delta: { stop_reason: "end_turn", stop_sequence: null }, usage });
      send("message_stop", {});
      res.end();
    });
  })
  .listen(0, "127.0.0.1", function () {
    fs.writeFileSync(`${dir}/port`, String(this.address().port));
  });
