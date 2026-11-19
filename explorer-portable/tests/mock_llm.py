#!/usr/bin/env python3
"""Scripted OpenAI-compatible mock model server for tests/Run-HostSmoke.ps1 (test-only, not shipped logic).

Each chat request is matched to a scenario by the latest "SCENARIO:<name>" marker found in a user
message. Every request that carries tools advances that scenario's step counter; requests without
tools are summarisation calls (answered with a fixed summary) or connection tests (answered "OK").

Control endpoints:  POST /__reset   GET /__log   GET /v1/models
Every request's message list is checked for OpenAI tool-call pairing; violations are logged.
"""
import json
import re
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LOCK = threading.Lock()
COUNTERS = {}
LOG = []


def tc(name, args):
    return {"tool": name, "args": args}


LONG_CMD = '1..3000 | ForEach-Object { "line $_ padding padding padding" }'

SCRIPTS = {
    "basic": [
        [tc("net_query", {"command": "Get-Date | Select-Object Year", "purpose": "year check"}),
         tc("kb_write", {"file": "00-index.md", "content": "# Index\n- 20-network.md - subnets\n"})],
        [tc("net_query", {"command": "Remove-Item C:\\x", "purpose": "bad idea"})],
        {"text": "Basic done."},
    ],
    "approve": [[tc("run_command", {"command": "Write-Output approved-run-ok"})], {"text": "Approve scenario done."}],
    "deny": [[tc("run_command", {"command": "Write-Output denied-run-should-not-appear"})], {"text": "Deny scenario done."}],
    "loop": [
        [tc("net_query", {"command": "Stop-Computer", "purpose": "x"})],
        [tc("net_query", {"command": "Stop-Computer", "purpose": "x"})],
        [tc("net_query", {"command": "Stop-Computer", "purpose": "x"})],
        [tc("net_query", {"command": "Restart-Service spooler", "purpose": "y"})],
        [tc("net_query", {"command": "Set-Content a b", "purpose": "z"})],
        [tc("net_query", {"command": "Remove-Item b", "purpose": "w"})],
        {"text": "Loop done."},
    ],
    "budget": [{"repeat_frontier": True}],
    "explore": [
        [tc("frontier", {"action": "add", "items": [
            {"target": "10.9.0.0/24", "question": "Which hosts answer?", "priority": 1},
            {"target": "esx01", "question": "What VMs run here?", "priority": 2}]})],
        [tc("kb_write", {"file": "20-network.md", "content": "# Network\n- 10.9.0.0/24 (raw/x.txt)\n"}),
         tc("frontier", {"action": "done", "id": "F001", "note": "mapped"})],
        {"text": "Finished F001."},
        [tc("frontier", {"action": "done", "id": "F002", "note": "esx01 has 3 VMs INFERRED"})],
        {"text": "Explore complete."},
    ],
    "compact": [
        [tc("net_query", {"command": LONG_CMD, "purpose": "long a"})],
        [tc("net_query", {"command": LONG_CMD, "purpose": "long b"})],
        [tc("net_query", {"command": LONG_CMD, "purpose": "long c"})],
        {"text": "Compact done."},
    ],
    "retry": [{"status": 500, "body": "transient upstream error"}, {"text": "Recovered after retry."}],
    "fail": [{"status": 500, "body": "model exploded badly", "sticky": True}],
    "slow": [{"sleep": 30, "then": {"text": "too late"}}],
    "stoprun": [[tc("run_command", {"command": "Start-Sleep -Seconds 30; Write-Output never-printed", "timeout_sec": 60})],
                {"text": "should not get here"}],
    "plugin": [{"plugin_scan": "local"}, {"plugin_scan": "outside"}, {"text": "Plugin done."}],
    "delegate": [[tc("delegate", {"task": "SCENARIO:sub Read the kb index and summarise it."})], {"text": "Delegate done."}],
    "sub": [[tc("kb_read", {})], {"text": "Sub summary: kb has an index."}],
}


def text_of(content):
    if isinstance(content, list):
        return " ".join(str(p.get("text", "")) for p in content if isinstance(p, dict))
    return str(content or "")


def check_pairing(messages):
    problems = []
    i = 0
    n = len(messages)
    while i < n:
        m = messages[i]
        role = m.get("role")
        if role == "tool":
            problems.append("orphan tool message at %d" % i)
            i += 1
            continue
        if role == "assistant" and m.get("tool_calls"):
            ids = [c.get("id") for c in m["tool_calls"]]
            if len(set(ids)) != len(ids) or not all(ids):
                problems.append("bad/duplicate tool_call ids at %d" % i)
            got = []
            j = i + 1
            while j < n and messages[j].get("role") == "tool":
                got.append(messages[j].get("tool_call_id"))
                j += 1
            if sorted(got) != sorted(ids):
                problems.append("tool results %s do not match calls %s at %d" % (got, ids, i))
            i = j
            continue
        i += 1
    return problems


def find_scenario(messages):
    # The latest user message with a marker wins (earlier turns of the same chat are history).
    for m in reversed(messages):
        if m.get("role") == "user":
            mm = re.search(r"SCENARIO:(\w+)", text_of(m.get("content")))
            if mm:
                return mm.group(1)
    return None


def find_ports(messages):
    for m in messages:
        if m.get("role") == "user":
            mm = re.search(r"PORTS:(\d+),(\d+)", text_of(m.get("content")))
            if mm:
                return [int(mm.group(1)), int(mm.group(2))]
    return [1, 2]


def completion(text=None, calls=None):
    msg = {"role": "assistant", "content": text if text is not None else ""}
    if calls:
        msg["tool_calls"] = calls
        msg["content"] = ""
    return {"id": "cmpl", "object": "chat.completion", "model": "mock-model",
            "choices": [{"index": 0, "message": msg, "finish_reason": "tool_calls" if calls else "stop"}]}


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def send_json(self, status, obj):
        body = json.dumps(obj).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def do_GET(self):
        if self.path.endswith("/models"):
            return self.send_json(200, {"data": [{"id": "mock-model"}]})
        if self.path == "/__log":
            with LOCK:
                return self.send_json(200, {"log": LOG})
        self.send_json(404, {"error": "nf"})

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b""
        if self.path == "/__reset":
            with LOCK:
                COUNTERS.clear()
                LOG.clear()
            return self.send_json(200, {"ok": True})
        if not self.path.endswith("/chat/completions"):
            return self.send_json(404, {"error": "nf"})
        req = json.loads(raw.decode("utf-8"))
        messages = req.get("messages", [])
        tools = req.get("tools") or []
        scenario = find_scenario(messages)
        entry = {"scenario": scenario, "hasTools": bool(tools), "toolNames": [t["function"]["name"] for t in tools],
                 "violations": check_pairing(messages), "messages": messages, "raw": raw.decode("utf-8"),
                 "authorization": "Authorization" in self.headers}
        if not tools:
            with LOCK:
                LOG.append(entry)
            joined = " ".join(text_of(m.get("content")) for m in messages)
            if "[Progress summary request]" in joined:
                return self.send_json(200, completion("SUMMARY: long queries ran; results are in raw/."))
            return self.send_json(200, completion("OK"))
        if scenario not in SCRIPTS:
            with LOCK:
                LOG.append(entry)
            return self.send_json(200, completion("OK (no scenario)"))
        with LOCK:
            idx = COUNTERS.get(scenario, 0)
            script = SCRIPTS[scenario]
            step = script[min(idx, len(script) - 1)]
            if not (isinstance(step, dict) and step.get("sticky")):
                COUNTERS[scenario] = idx + 1
            entry["step"] = idx
            LOG.append(entry)
        if isinstance(step, dict) and "sleep" in step:
            time.sleep(step["sleep"])
            step = step["then"]
        if isinstance(step, dict) and "status" in step:
            return self.send_json(step["status"], {"error": {"message": step["body"]}})
        if isinstance(step, dict) and step.get("repeat_frontier"):
            step = [tc("frontier", {"action": "add", "items": [{"target": "host%d" % idx, "question": "q%d" % idx}]})]
        if isinstance(step, dict) and "plugin_scan" in step:
            if step["plugin_scan"] == "local":
                step = [tc("plg_portscan_scan", {"target": "127.0.0.1", "ports": find_ports(messages)})]
            else:
                step = [tc("plg_portscan_scan", {"target": "8.8.8.8", "ports": [53]})]
        if isinstance(step, dict) and "text" in step:
            return self.send_json(200, completion(step["text"]))
        calls = []
        for k, c in enumerate(step):
            calls.append({"id": "call_%s_%d_%d" % (scenario, idx, k), "type": "function",
                          "function": {"name": c["tool"], "arguments": json.dumps(c["args"])}})
        return self.send_json(200, completion(calls=calls))


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 0
    srv = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    srv.daemon_threads = True
    print("PORT %d" % srv.server_address[1], flush=True)
    srv.serve_forever()


if __name__ == "__main__":
    main()
