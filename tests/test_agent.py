"""Tin's agent contract against a local OpenCode-compatible server. No model calls."""

import base64
import json
import os
import shutil
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit


BINARY = str(Path(sys.argv.pop(1)).resolve()) if len(sys.argv) > 1 else "tin"


class AgentContract(unittest.TestCase):
    def setUp(self):
        # Keep the isolated tmux Unix socket below macOS's path-length limit.
        self.temp = tempfile.TemporaryDirectory(prefix="ta-")
        home = Path(self.temp.name)
        self.tin_dir = home / ".tin"
        self.tin_dir.mkdir()
        self.env = {**os.environ, "HOME": str(home), "TIN_DIR": str(self.tin_dir), "TIN_AUTO_SERVER": "0"}
        self.env.pop("TMUX", None)
        self.env["TMUX_TMPDIR"] = str(home)
        self.tmux_started = False
        self.calls = []
        self.fail_child = False
        self.bad_status = False
        self.sessions = {
            "ses_parent": {"id": "ses_parent", "title": "Control: feature", "directory": "/remote/project"},
            "ses_child": {"id": "ses_child", "title": "worker", "parentID": "ses_parent", "directory": "/remote/worktree"},
        }
        owner = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_GET(self):
                self.respond()

            def do_POST(self):
                self.respond()

            def respond(self):
                url = urlsplit(self.path)
                raw = self.rfile.read(int(self.headers.get("Content-Length", 0)))
                body = json.loads(raw) if raw else None
                owner.calls.append((self.command, url.path, parse_qs(url.query), body, self.headers))
                status, value = 200, True
                if self.headers.get("Authorization") != "Basic " + base64.b64encode(b"opencode:fixture-secret").decode():
                    status, value = 401, {"error": "unauthorized"}
                elif url.path == "/session" and self.command == "POST":
                    value = {"id": f"ses_created{len(owner.sessions)}", "title": body["title"], "directory": parse_qs(url.query)["directory"][0]}
                    owner.sessions[value["id"]] = value
                elif url.path == "/session":
                    value = list(owner.sessions.values())
                elif url.path == "/session/status":
                    value = {"ses_child": {"type": "busy"}} if not owner.bad_status else []
                elif url.path == "/permission":
                    value = [{"id": "per_one", "sessionID": "ses_child", "permission": "bash", "patterns": ["make test"]}]
                elif url.path == "/question":
                    value = []
                elif url.path.endswith("/children"):
                    # A cycle verifies that recursive stopping cannot loop forever.
                    value = [owner.sessions["ses_child"]] if "ses_parent" in url.path else [owner.sessions["ses_parent"]]
                elif url.path.endswith("/abort") and "ses_child" in url.path and owner.fail_child:
                    status, value = 500, {"error": "failed"}
                elif url.path.endswith("/prompt_async"):
                    status, value = 204, None
                elif url.path.endswith("/diff"):
                    value = [{"file": "code.lua", "patch": "@@ -1 +1 @@\n-old\n+new\n", "additions": 1, "deletions": 1}]
                elif url.path.endswith("/message") or url.path.endswith("/todo"):
                    value = []
                elif url.path.count("/") == 2 and url.path.startswith("/session/"):
                    value = owner.sessions[url.path.split("/")[-1]]
                payload = json.dumps(value).encode() if value is not None else b""
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.url = f"http://127.0.0.1:{self.server.server_port}"
        self.write_config()
        (self.tin_dir / ".env").write_text("TEST_AGENT_PASSWORD=fixture-secret\n")

    def tearDown(self):
        if self.tmux_started:
            subprocess.run(["tmux", "kill-server"], env=self.env, capture_output=True, timeout=10)
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()
        self.temp.cleanup()

    def write_config(self, url=None):
        (self.tin_dir / "tinrc.yml").write_text(
            f"agents:\n  - name: local\n    url: {url or self.url}\n"
            "    directory: /remote/project\n    password_env: TEST_AGENT_PASSWORD\n"
        )

    def cli(self, *args, input=None, code=0):
        result = subprocess.run([BINARY, "agent", *args], input=input, text=True, capture_output=True, env=self.env, timeout=20)
        self.assertEqual(code, result.returncode, result.stderr + result.stdout)
        self.assertNotIn("fixture-secret", result.stdout + result.stderr)
        return json.loads(result.stdout) if result.stdout.strip() else result.stderr

    def test_servers_are_discovered_without_contacting_runtime(self):
        servers = self.cli("servers", "--directory", "/local/editor")
        self.assertEqual("/remote/project", servers[0]["directory"])
        self.assertEqual([], self.calls)

    def test_snapshot_contains_attention_and_status(self):
        self.sessions["ses_unrelated"] = {"id": "ses_unrelated", "title": "other group", "directory": "/another/worktree"}
        snapshot = self.cli("snapshot")
        self.assertEqual("busy", snapshot["status"]["ses_child"]["type"])
        self.assertEqual("per_one", snapshot["permissions"][0]["id"])
        self.assertEqual({"ses_parent", "ses_child"}, {item["id"] for item in snapshot["sessions"]})
        self.assertEqual({"/remote/project", "/remote/worktree"}, {call[2]["directory"][0] for call in self.calls})
        self.assertEqual(1, len(snapshot["permissions"]))

    def test_coordinator_prompt_is_literal_and_uses_native_delegation(self):
        text = 'Fix this\n"quoted" \\ $(touch /tmp/never)\n```lua\nreturn 1\n```'
        self.cli("prompt", "ses_parent", input=text)
        method, path, _, body, _ = self.calls[-1]
        self.assertEqual(("POST", "/session/ses_parent/prompt_async"), (method, path))
        self.assertEqual(text, body["parts"][0]["text"])
        self.assertIn("task tool", body["system"])
        self.assertEqual("tin-coordinator", body["agent"])

    def test_worker_prompt_uses_actual_worktree_and_preserves_agent(self):
        self.cli("prompt", "ses_child", input="Continue")
        self.assertEqual(["/remote/worktree"], self.calls[-1][2]["directory"])
        self.assertNotIn("system", self.calls[-1][3])
        self.assertNotIn("agent", self.calls[-1][3])

    def test_create_and_inspect_and_diff(self):
        self.assertEqual("Control: new task", self.cli("create", "new task")["title"])
        self.assertEqual([], self.cli("inspect", "ses_child")["todos"])
        self.assertIn("+new", self.cli("diff", "ses_child")[0]["patch"])

    def test_stop_tree_stops_parent_first_and_reports_partial_failure(self):
        self.fail_child = True
        result = self.cli("stop", "ses_parent", "--tree", code=1)
        self.assertEqual(["ses_parent"], result["stopped"])
        self.assertIn("ses_child", result["errors"][0])
        stops = [call for call in self.calls if call[1].endswith("/abort")]
        self.assertEqual(["/session/ses_parent/abort", "/session/ses_child/abort"], [call[1] for call in stops])
        self.assertEqual(["/remote/worktree"], stops[1][2]["directory"])

    def test_stop_one_does_not_stop_children(self):
        self.assertEqual(["ses_parent"], self.cli("stop", "ses_parent")["stopped"])
        self.assertFalse(any(call[1].endswith("/children") for call in self.calls))

    def test_permission_and_multiselect_answers(self):
        self.cli("permission", "per_one", "once")
        self.assertEqual({"reply": "once"}, self.calls[-1][3])
        self.cli("answer", "que_one", input='[["A", "B"], ["custom answer"]]')
        self.assertEqual({"answers": [["A", "B"], ["custom answer"]]}, self.calls[-1][3])
        self.cli("reject-question", "que_one")
        self.assertEqual("/question/que_one/reject", self.calls[-1][1])

    def test_bad_input_never_reaches_server(self):
        for args in [("prompt", "ses_../other"), ("stop", "ses_parent", "--unknown"), ("permission", "per_one", "yes"), ("snapshot", "--directory", "relative")]:
            self.cli(*args, code=1)
        self.cli("answer", "que_one", input='["not nested"]', code=1)
        self.assertEqual([], self.calls)

    def test_auth_and_invalid_response_are_reported(self):
        (self.tin_dir / ".env").write_text("TEST_AGENT_PASSWORD=wrong\n")
        self.assertIn("AuthenticationFailed", self.cli("snapshot", code=1))
        (self.tin_dir / ".env").write_text("TEST_AGENT_PASSWORD=fixture-secret\n")
        self.bad_status = True
        self.assertIn("InvalidResponse", self.cli("snapshot", code=1))

    def test_url_cannot_smuggle_credentials_paths_or_curl_flags(self):
        for url in ["http://name:password@localhost:4096", self.url + "/path", self.url + "?x=1", "file:///tmp/config"]:
            self.write_config(url)
            self.assertIn("InvalidServerURL", self.cli("servers", code=1))
        self.assertEqual([], self.calls)

    def test_serve_uses_selected_port_directory_and_managed_credentials(self):
        home = Path(self.temp.name)
        tools = home / "server-tools"
        tools.mkdir()
        executable = tools / "opencode"
        executable.write_text(
            "#!/usr/bin/env python3\nimport os, sys\n"
            f"assert sys.argv[1:] == ['serve', '--hostname', '127.0.0.1', '--port', '{self.server.server_port}']\n"
            "assert os.environ['OPENCODE_SERVER_PASSWORD'] == 'fixture-secret'\n"
            "assert os.environ['OPENCODE_SERVER_USERNAME'] == 'opencode'\n"
            f"assert os.path.samefile(os.getcwd(), {str(home)!r})\n"
            "print('{\"valid\":true}')\n"
        )
        executable.chmod(0o755)
        self.env["PATH"] = str(tools) + os.pathsep + os.environ["PATH"]
        self.assertEqual({"valid": True}, self.cli("serve", "--directory", str(home)))

    @unittest.skipUnless(shutil.which("tmux") and shutil.which("git"), "tmux and git required")
    def test_worktree_group_reuses_branch_conversation_and_side_pane(self):
        home = Path(self.temp.name)
        tools = home / "tools"
        tools.mkdir()
        for tool in ("nvim", "opencode"):
            executable = tools / tool
            executable.write_text("#!/bin/sh\nexec sleep 60\n")
            executable.chmod(0o755)
        self.env["PATH"] = str(tools) + os.pathsep + os.environ["PATH"]
        repo = home / "repo"
        source = Path(__file__).resolve().parents[1]
        subprocess.run(["git", "clone", "--shared", "--no-checkout", str(source), str(repo)], check=True, capture_output=True, env=self.env)
        self.tmux_started = True
        group = self.cli("worktree", "tin-fixture", "--directory", str(repo))
        self.assertTrue(Path(group["directory"]).is_dir())
        reopened = self.cli("open", group["directory"])
        self.assertEqual(group["window"], reopened["window"])
        self.assertEqual(group["coordinator"], reopened["coordinator"])
        reused = self.cli("worktree", "tin-fixture", "--directory", str(repo))
        self.assertEqual(group["directory"], reused["directory"])
        self.assertEqual(1, len(self.cli("groups")))
        panes = subprocess.run(["tmux", "list-panes", "-t", group["window"], "-F", "#{pane_id}"], env=self.env, text=True, capture_output=True, check=True).stdout.splitlines()
        self.assertEqual(2, len(panes))
        connections = self.cli("servers")
        self.assertTrue(any(connection["directory"] == group["directory"] for connection in connections))
        context = subprocess.run(["tmux", "display-message", "-p", "-t", panes[0], "#{socket_path},#{pid},0"], env=self.env, text=True, capture_output=True, check=True).stdout.strip()
        self.env["TMUX"], self.env["TMUX_PANE"] = context, panes[0]
        binding = self.cli("group", "--directory", group["directory"])
        self.assertEqual(group["coordinator"], binding["session"])
        self.assertEqual(group["window"], binding["group"].split("/")[0])
        self.assertEqual(group["coordinator"], binding["coordinator"])
        scoped = self.cli("snapshot", "--group", binding["group"], "--directory", group["directory"])
        self.assertEqual({group["coordinator"]}, {session["id"] for session in scoped["sessions"]})
        self.assertNotIn("ses_parent", {session["id"] for session in scoped["sessions"]})
        created = self.cli("create", "scoped task", "--group", binding["group"], "--directory", group["directory"])
        self.assertEqual(group["coordinator"], self.calls[-1][3]["parentID"])
        self.assertIn(
            "OutsideGroup",
            self.cli("prompt", "ses_parent", "--group", binding["group"], "--directory", group["directory"], input="hi", code=1),
        )
        self.assertIn(
            "GroupChanged",
            self.cli("snapshot", "--group", binding["group"] + "/x", "--directory", group["directory"], code=1),
        )

    def test_open_new_creates_fresh_coordinator_in_same_window(self):
        home = Path(self.temp.name)
        tools = home / "tools"
        tools.mkdir()
        for tool in ("nvim", "opencode"):
            executable = tools / tool
            executable.write_text("#!/bin/sh\nexec sleep 60\n")
            executable.chmod(0o755)
        self.env["PATH"] = str(tools) + os.pathsep + os.environ["PATH"]
        repo = home / "repo"
        source = Path(__file__).resolve().parents[1]
        subprocess.run(["git", "clone", "--shared", "--no-checkout", str(source), str(repo)], check=True, capture_output=True, env=self.env)
        self.tmux_started = True
        group = self.cli("open", str(repo), "--directory", str(repo))
        fresh = self.cli("open", str(repo), "--directory", str(repo), "--new")
        self.assertEqual(group["window"], fresh["window"])
        self.assertNotEqual(group["coordinator"], fresh["coordinator"])
        self.assertEqual(1, len(self.cli("groups")))
        panes = subprocess.run(["tmux", "list-panes", "-t", fresh["window"], "-F", "#{pane_id}"], env=self.env, text=True, capture_output=True, check=True).stdout.splitlines()
        self.assertEqual(2, len(panes))
        coordinator = subprocess.run(
            ["tmux", "display-message", "-p", "-t", fresh["window"], "#{@tin_coordinator}"],
            env=self.env, text=True, capture_output=True, check=True,
        ).stdout.strip()
        self.assertEqual(fresh["coordinator"], coordinator)

    def test_new_flag_is_rejected_for_other_actions(self):
        self.assertIn("Usage", self.cli("snapshot", "--new", code=1))

    def test_group_scoping_requires_a_live_tin_group(self):
        for args in [("group",), ("snapshot", "--group", "at/w0/coordinator")]:
            self.assertIn("NotInTinGroup", self.cli(*args, code=1))
        self.assertEqual([], self.calls)


if __name__ == "__main__":
    unittest.main()
