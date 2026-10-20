#!/usr/bin/env python3
"""CI용 Google OAuth·YouTube Data API 흉내 (P8 유튜브 로그인 시험).

앱을 `-autotest-youtube http://127.0.0.1:<포트>`로 띄우면 이 서버로 로그인 흐름 전체를 돈다.
- /o/oauth2/v2/auth: 요청을 확인하고 code_challenge를 기억한 뒤, 로그인 창이 돌려줄 콜백 주소를 본문으로 준다
- /token: 코드 교환(PKCE 확인)과 토큰 갱신
- /youtube/v3/...: channels, liveStreams, liveBroadcasts, liveBroadcasts/bind
첫 액세스 토큰은 채널 조회 뒤 만료된 것으로 다뤄(401) 앱이 갱신하는지 본다.
수신 주소는 러너의 ffmpeg RTMP 수신(rtmp://127.0.0.1:1935/live, 키 autotest).

사용법: youtube-mock.py <포트>
"""

import base64
import hashlib
import json
import sys
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

STATE = {"challenge": None, "client_id": None, "redirect_uri": None, "streams": [], "expired": set()}


def log(message):
    print(message, flush=True)


class Handler(BaseHTTPRequestHandler):
    def reply(self, status, body, content_type="application/json"):
        data = body.encode() if isinstance(body, str) else json.dumps(body, ensure_ascii=False).encode()
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def fail(self, status, message):
        log(f"FAIL {self.command} {self.path}: {message}")
        self.reply(status, {"error": {"code": status, "message": message, "errors": [{"reason": "mock"}]}})

    def body(self):
        length = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(length).decode() if length else ""

    def authorized(self):
        token = (self.headers.get("Authorization") or "").removeprefix("Bearer ")
        if not token.startswith("mock-access-") or token in STATE["expired"]:
            log(f"401 {self.command} {urllib.parse.urlparse(self.path).path} ({token[:12]}...)")
            self.reply(401, {"error": {"code": 401, "message": "Invalid Credentials", "errors": [{"reason": "authError"}]}})
            return False
        return True

    def do_GET(self):
        url = urllib.parse.urlparse(self.path)
        query = dict(urllib.parse.parse_qsl(url.query))

        if url.path == "/o/oauth2/v2/auth":
            client_id = query.get("client_id", "")
            prefix = client_id.removesuffix(".apps.googleusercontent.com")
            expected_redirect = f"com.googleusercontent.apps.{prefix}:/oauth2redirect"
            problems = []
            if not client_id.endswith(".apps.googleusercontent.com"):
                problems.append("client_id")
            if query.get("redirect_uri") != expected_redirect:
                problems.append("redirect_uri")
            if query.get("response_type") != "code":
                problems.append("response_type")
            if "youtube" not in query.get("scope", ""):
                problems.append("scope")
            if query.get("code_challenge_method") != "S256" or len(query.get("code_challenge", "")) != 43:
                problems.append("pkce")
            if not query.get("state"):
                problems.append("state")
            if problems:
                return self.fail(400, "bad auth request: " + ", ".join(problems))

            STATE.update(challenge=query["code_challenge"], client_id=client_id, redirect_uri=expected_redirect)
            callback = expected_redirect + "?" + urllib.parse.urlencode(
                {"state": query["state"], "code": "mock-code", "scope": query["scope"]})
            log(f"auth ok (client {client_id})")
            return self.reply(200, callback, "text/plain")

        if not self.authorized():
            return
        if url.path == "/youtube/v3/channels":
            # 이 토큰은 여기까지만 쓰이고 만료된 것으로 다룬다 → 다음 호출에서 갱신해야 한다
            STATE["expired"].add("mock-access-1")
            log("channels ok")
            return self.reply(200, {"items": [{"id": "UCmock", "snippet": {"title": "시험 채널"}}]})
        if url.path == "/youtube/v3/liveStreams":
            log(f"liveStreams list ({len(STATE['streams'])})")
            return self.reply(200, {"items": STATE["streams"]})
        return self.fail(404, "unknown path")

    def do_POST(self):
        url = urllib.parse.urlparse(self.path)
        query = dict(urllib.parse.parse_qsl(url.query))
        raw = self.body()

        if url.path == "/token":
            form = dict(urllib.parse.parse_qsl(raw))
            grant = form.get("grant_type")
            if grant == "authorization_code":
                verifier = form.get("code_verifier", "")
                challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).decode().rstrip("=")
                if form.get("code") != "mock-code" or challenge != STATE["challenge"]:
                    log("FAIL token: code or PKCE verifier mismatch")
                    return self.reply(400, {"error": "invalid_grant"})
                if form.get("client_id") != STATE["client_id"] or form.get("redirect_uri") != STATE["redirect_uri"]:
                    log("FAIL token: client_id or redirect_uri mismatch")
                    return self.reply(400, {"error": "invalid_client"})
                log("pkce ok")
                return self.reply(200, {"access_token": "mock-access-1", "expires_in": 3599,
                                        "refresh_token": "mock-refresh", "token_type": "Bearer"})
            if grant == "refresh_token":
                if form.get("refresh_token") != "mock-refresh":
                    return self.reply(400, {"error": "invalid_grant"})
                # 갱신 토큰은 그것을 받은 클라이언트로만 갱신된다
                if form.get("client_id") != STATE["client_id"]:
                    log("FAIL token: refresh with another client_id")
                    return self.reply(400, {"error": "unauthorized_client"})
                log("refresh ok")
                return self.reply(200, {"access_token": "mock-access-2", "expires_in": 3599, "token_type": "Bearer"})
            return self.reply(400, {"error": "unsupported_grant_type"})

        if url.path == "/revoke":
            return self.reply(200, {})

        if not self.authorized():
            return
        body = json.loads(raw) if raw else {}

        if url.path == "/youtube/v3/liveStreams":
            if body.get("snippet", {}).get("title") != "Broadcast (iPad)" or \
                    body.get("cdn", {}).get("ingestionType") != "rtmp" or \
                    body.get("contentDetails", {}).get("isReusable") is not True:
                return self.fail(400, "bad liveStreams.insert body")
            stream = {
                "id": "mockStream1",
                "snippet": body["snippet"],
                "cdn": {"ingestionType": "rtmp", "ingestionInfo": {
                    "streamName": "autotest",
                    "ingestionAddress": "rtmp://127.0.0.1:1935/live",
                    "rtmpsIngestionAddress": "rtmp://127.0.0.1:1935/live",
                }},
                "contentDetails": {"isReusable": True},
            }
            STATE["streams"].append(stream)
            log("stream created")
            return self.reply(200, stream)

        if url.path == "/youtube/v3/liveBroadcasts":
            snippet, status, details = body.get("snippet", {}), body.get("status", {}), body.get("contentDetails", {})
            problems = []
            if snippet.get("title") != "CI 시험 방송":  # 앱이 < > 를 지웠어야 한다
                problems.append(f"title {snippet.get('title')!r}")
            if not snippet.get("scheduledStartTime"):
                problems.append("scheduledStartTime")
            if status.get("privacyStatus") != "unlisted" or status.get("selfDeclaredMadeForKids") is not False:
                problems.append("status")
            if details.get("enableAutoStart") is not True or details.get("enableAutoStop") is not True:
                problems.append("auto start/stop")
            if problems:
                return self.fail(400, "bad liveBroadcasts.insert body: " + ", ".join(problems))
            log("broadcast ok")
            return self.reply(200, {"id": "mockBroadcast1", "snippet": snippet, "status": status})

        if url.path == "/youtube/v3/liveBroadcasts/bind":
            if query.get("id") != "mockBroadcast1" or query.get("streamId") != "mockStream1":
                return self.fail(400, f"bad bind {query}")
            log("bind ok")
            return self.reply(200, {"id": "mockBroadcast1", "contentDetails": {"boundStreamId": "mockStream1"}})

        return self.fail(404, "unknown path")


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8098
    log(f"youtube mock on 127.0.0.1:{port}")
    ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
