#!/usr/bin/env python3
"""CI용 Google OAuth·YouTube Data API 흉내 (P8 유튜브 로그인 시험).

앱을 `-autotest-youtube http://127.0.0.1:<포트>`로 띄우면 이 서버로 로그인 흐름 전체를 돈다.
- /o/oauth2/v2/auth: 요청을 확인하고 code_challenge를 기억한 뒤, 로그인 창이 돌려줄 콜백 주소를 본문으로 준다
- /token: 코드 교환(PKCE 확인)과 토큰 갱신
- /youtube/v3/...: channels, liveStreams, liveBroadcasts, liveBroadcasts/bind
첫 액세스 토큰은 채널 조회 뒤 만료된 것으로 다뤄(401) 앱이 갱신하는지 본다.
수신 주소는 러너의 ffmpeg RTMP 수신(rtmp://127.0.0.1:1935/live, 키 autotest).

채팅 (P7, 앱 인자 `-autotest-chat <이 주소>`): 유튜브 웹 채팅과 공식 API의 형식을 흉내 낸다.
- /live_chat: 채팅 팝업 페이지 (ytInitialData). 앱이 직접 받을 때(URLSession)와 패널(WebKit)이 띄울 때를
  Accept 헤더로 나눈다. 패널 페이지에는 진짜 페이지처럼 get_live_chat을 fetch로 되풀이하는 스크립트가 있다.
  직접 받기의 두 번째 페이지부터는 형식이 바뀐 페이지를 줘서 앱이 공식 API로 넘어가는지 본다.
- /youtubei/v1/live_chat/get_live_chat: 단계별 메시지·삭제 (continuation "<d|p>-<top|live>-<n|reload>")
- /youtube/v3/liveChat/messages: 공식 API (첫 응답은 지난 메시지)
메시지 id: d- 직접, p- 패널, a- API, hist-·old- 는 지난 메시지라 앱이 채팅 소스로 보내면 안 된다.
위험한 입력(마크업, 함정 서버 127.0.0.1:8099의 그림 주소)도 섞는다.

사용법: youtube-mock.py <포트>
"""

import base64
import hashlib
import json
import sys
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

STATE = {"challenge": None, "client_id": None, "redirect_uri": None, "streams": [], "expired": set()}
CHAT = {"direct_pages": 0, "webkit_pages": 0}
CLIENT_VERSION = "2.20261019.01.00"
EVIL = "http://127.0.0.1:8099/"


def log(message):
    print(message, flush=True)


def now_usec(offset_seconds=0):
    return str(int((time.time() + offset_seconds) * 1_000_000))


def author_fields(name, channel, badges=None):
    fields = {
        "authorName": {"simpleText": name},
        "authorExternalChannelId": channel,
        "authorPhoto": {"thumbnails": [{"url": "https://yt4.ggpht.com/mock=s32", "width": 32, "height": 32}]},
    }
    if badges:
        fields["authorBadges"] = badges
    return fields


def add(renderer, item):
    return {"addChatItemAction": {"item": {renderer: item}}}


def text(message_id, name, runs, channel=None, badges=None, age=0):
    item = {"id": message_id, "timestampUsec": now_usec(-age), "message": {"runs": runs}}
    item.update(author_fields(name, channel or "UC" + message_id, badges))
    return add("liveChatTextMessageRenderer", item)


def direct_step(step):
    """직접 받기: 보통 글, 슈퍼챗, 위험한 입력, 지난 메시지, 자리표시 → 멤버, 이모지, 스팸, 자리표시 교체 → 삭제"""
    if step == 1:
        paid = {"id": "d-2", "timestampUsec": now_usec(), "purchaseAmountText": {"simpleText": "₩5,000"},
                "bodyBackgroundColor": 4280191205, "headerBackgroundColor": 4278239141,
                "message": {"runs": [{"text": "응원합니다 💪"}]}}
        paid.update(author_fields("후원자", "UCdonor"))
        return [
            text("d-1", "시청자A", [{"text": "직접 받은 첫 채팅입니다 👋"}]),
            add("liveChatPaidMessageRenderer", paid),
            text("d-3", "<b>해커</b><script>alert(1)</script>", [
                {"text": f'<img src="{EVIL}evil-yt-text.png" onerror="alert(2)"><script>alert(3)</script>'},
                {"emoji": {"emojiId": "UCevil/emoji", "isCustomEmoji": True, "shortcuts": [":evil:"],
                           "image": {"thumbnails": [{"url": EVIL + "evil-yt-emoji.png"}]}}},
                {"text": "링크", "navigationEndpoint": {"urlEndpoint": {"url": EVIL + "evil-yt-link"}}},
            ], badges=[{"liveChatAuthorBadgeRenderer": {
                "customThumbnail": {"thumbnails": [{"url": EVIL + "evil-yt-badge.png"}]}, "tooltip": "멤버"}}]),
            text("old-1", "지난 메시지", [{"text": "5분 전 글 (보이면 안 됨)"}], age=300),
            add("liveChatPlaceholderItemRenderer", {"id": "d-7", "timestampUsec": now_usec()}),
        ]
    if step == 2:
        member = {"id": "d-4", "timestampUsec": now_usec(), "headerSubtext": {"runs": [{"text": "새 멤버가 되었어요"}]}}
        member.update(author_fields("새멤버", "UCmember"))
        return [
            add("liveChatMembershipItemRenderer", member),
            text("d-5", "방송자", [{"text": "이모지 "}, {"emoji": {
                "emojiId": "😀", "shortcuts": [":grinning:"],
                "image": {"thumbnails": [{"url": "https://fonts.gstatic.com/s/e/notoemoji/15.1/1f600/72.png"}]}}}],
                 channel="UCmock", badges=[{"liveChatAuthorBadgeRenderer": {"icon": {"iconType": "OWNER"},
                                                                          "tooltip": "소유자"}}]),
            text("d-6", "스팸", [{"text": "광고입니다 (작성자 차단으로 지워져야 함)"}], channel="UCspam"),
            {"replaceChatItemAction": {"targetItemId": "d-7", "replacementItem": {"liveChatTextMessageRenderer": {
                "id": "d-7", "timestampUsec": now_usec(), "message": {"runs": [{"text": "검토 뒤 나온 글"}]},
                **author_fields("검토됨", "UCheld")}}}},
        ]
    if step == 4:
        return [
            {"removeChatItemAction": {"targetItemId": "d-1"}},
            {"removeChatItemByAuthorAction": {"externalChannelId": "UCspam"}},
        ]
    return []


def page_step(step):
    """패널 페이지: 새 글 둘과 직접 받기에서 이미 보낸 슈퍼챗(중복) → 삭제"""
    if step == 1:
        paid = {"id": "d-2", "timestampUsec": now_usec(), "purchaseAmountText": {"simpleText": "₩5,000"},
                "bodyBackgroundColor": 4280191205, "message": {"runs": [{"text": "응원합니다 💪"}]}}
        paid.update(author_fields("후원자", "UCdonor"))
        return [
            text("p-1", "패널시청자", [{"text": "패널 페이지에서 읽은 글"}]),
            text("p-2", "패널시청자2", [{"text": "두 번째 글"}]),
            add("liveChatPaidMessageRenderer", paid),
        ]
    if step == 3:
        return [{"markChatItemAsDeletedAction": {"targetItemId": "p-1"}}]
    return []


def initial_data(session):
    return {"contents": {"liveChatRenderer": {
        "actions": [text("hist-1", "지난 시청자", [{"text": "지난 글 1"}], age=60),
                    text("hist-2", "지난 시청자", [{"text": "지난 글 2"}], age=30)],
        "continuations": [{"invalidationContinuationData": {"continuation": f"{session}-top-1", "timeoutMs": 1000}}],
        "header": {"liveChatHeaderRenderer": {"viewSelector": {"sortFilterSubMenuRenderer": {"subMenuItems": [
            {"title": "주요 채팅", "selected": True,
             "continuation": {"reloadContinuationData": {"continuation": f"{session}-top-reload"}}},
            {"title": "실시간 채팅", "selected": False,
             "continuation": {"reloadContinuationData": {"continuation": f"{session}-live-reload"}}},
        ]}}}},
    }}}


# 패널 페이지: 진짜 페이지처럼 메시지를 화면에 그리고 get_live_chat을 fetch로 되풀이한다
PAGE_SCRIPT = r"""
(function () {
  var data = window.ytInitialData.contents.liveChatRenderer;
  var cont = data.continuations[0].invalidationContinuationData.continuation;
  var list = document.getElementById('items');
  function show(actions) {
    (actions || []).forEach(function (action) {
      var item = action.addChatItemAction && action.addChatItemAction.item;
      if (item) {
        var name = Object.keys(item)[0];
        var renderer = item[name];
        var element = document.createElement('yt-' + name.replace(/[A-Z]/g, function (c) { return '-' + c.toLowerCase(); }));
        element.id = renderer.id;
        var runs = (renderer.message && renderer.message.runs) || [];
        element.textContent = ((renderer.authorName && renderer.authorName.simpleText) || '') + '  ' +
          runs.map(function (run) { return run.text || (run.emoji && run.emoji.emojiId) || ''; }).join('');
        list.appendChild(element);
      }
      var deleted = action.markChatItemAsDeletedAction || action.removeChatItemAction;
      var gone = deleted && document.getElementById(deleted.targetItemId);
      if (gone) gone.textContent = '(메시지 삭제됨)';
    });
  }
  show(data.actions);
  function poll() {
    fetch('/youtubei/v1/live_chat/get_live_chat?prettyPrint=false', {
      method: 'POST', headers: {'Content-Type': 'application/json'},
      body: JSON.stringify({context: {client: {clientName: 'WEB', clientVersion: '""" + CLIENT_VERSION + r"""'}},
                            continuation: cont})
    }).then(function (response) { return response.json(); }).then(function (json) {
      var chat = json.continuationContents.liveChatContinuation;
      show(chat.actions);
      var next = chat.continuations[0].invalidationContinuationData;
      cont = next.continuation;
      setTimeout(poll, next.timeoutMs);
    }).catch(function () { setTimeout(poll, 2000); });
  }
  setTimeout(poll, 500);
})();
"""


def chat_page(session):
    initial = json.dumps(initial_data(session), ensure_ascii=False)
    return ("<!DOCTYPE html><html><head><meta charset=\"utf-8\"><title>live chat mock</title>"
            "<meta name=\"viewport\" content=\"width=device-width\">"
            "<style>body { margin: 0; padding: 8px 12px; background: #0f0f0f; color: #f1f1f1;"
            " font: 15px -apple-system, sans-serif; } #items > * { display: block; padding: 4px 0; }</style>"
            "<script>var ytcfg = {set: function () {}}; ytcfg.set({\"INNERTUBE_CLIENT_VERSION\":\""
            + CLIENT_VERSION + "\"});</script></head><body><div id=\"items\"></div>"
            "<script>window[\"ytInitialData\"] = " + initial + ";</script>"
            "<script>" + PAGE_SCRIPT + "</script></body></html>")


def chat_continuation(token):
    session, mode, step = (token.split("-") + ["", ""])[:3]
    chat = {}
    if step == "reload":
        # 보기를 고를 때의 전체 목록 (지난 메시지)
        chat = {"header": {}, "itemList": {},
                "actions": [text("hist-3", "지난 시청자", [{"text": "지난 글 3"}], age=10)]}
        next_step = 1
    else:
        number = int(step) if step.isdigit() else 1
        chat = {"actions": direct_step(number) if session == "d" else page_step(number)}
        next_step = number + 1
    chat["continuations"] = [{"invalidationContinuationData": {
        "continuation": f"{session}-{mode}-{next_step}", "timeoutMs": 1000}}]
    return {"responseContext": {}, "continuationContents": {"liveChatContinuation": chat}}


def api_messages(token):
    """공식 API liveChatMessages.list"""
    def item(message_id, kind, author, snippet):
        base = {"type": kind, "liveChatId": "mockChat1", "publishedAt": time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime()),
                "hasDisplayContent": True}
        base.update(snippet)
        return {"kind": "youtube#liveChatMessage", "id": message_id, "snippet": base,
                "authorDetails": {"channelId": "UC" + message_id, "displayName": author, "isChatOwner": False,
                                  "isChatModerator": False, "isChatSponsor": False, "isVerified": False}}

    if not token:
        items = [item("hist-a1", "textMessageEvent", "지난 시청자", {"displayMessage": "API 지난 글"})]
        next_token = "api-1"
    elif token == "api-1":
        items = [
            item("a-1", "textMessageEvent", "API시청자", {"displayMessage": "공식 API로 받은 글"}),
            item("a-2", "superChatEvent", "API후원자", {"displayMessage": "₩10,000 고마워요", "superChatDetails": {
                "amountMicros": "10000000000", "currency": "KRW", "amountDisplayString": "₩10,000",
                "userComment": "고마워요", "tier": 4}}),
            item("a-3", "messageDeletedEvent", "관리자", {"messageDeletedDetails": {"deletedMessageId": "a-1"}}),
        ]
        next_token = "api-2"
    else:
        items = []
        next_token = "api-2"
    return {"kind": "youtube#liveChatMessageListResponse", "pollingIntervalMillis": 1000,
            "nextPageToken": next_token, "items": items}


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

        if url.path == "/live_chat":
            # 웹 채팅은 로그인 없이 받는다: 앱의 토큰이 여기로 가면 안 된다
            if self.headers.get("Authorization"):
                log("FAIL the chat page request carried a token")
            if query.get("v") != "mockBroadcast1":
                return self.fail(404, f"chat page for {query.get('v')}")
            if "text/html" in (self.headers.get("Accept") or ""):
                CHAT["webkit_pages"] += 1
                log(f"chat page webkit {CHAT['webkit_pages']}")
                return self.reply(200, chat_page("p"), "text/html; charset=utf-8")
            CHAT["direct_pages"] += 1
            if CHAT["direct_pages"] >= 2:
                log(f"chat page direct {CHAT['direct_pages']} (changed format)")
                return self.reply(200, "<!DOCTYPE html><html><body>new layout</body></html>", "text/html; charset=utf-8")
            log(f"chat page direct {CHAT['direct_pages']}")
            return self.reply(200, chat_page("d"), "text/html; charset=utf-8")

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
        if url.path == "/youtube/v3/liveBroadcasts":
            log("liveBroadcasts list")
            return self.reply(200, {"items": [{"id": "mockBroadcast1", "snippet": {"liveChatId": "mockChat1"}}]})
        if url.path == "/youtube/v3/liveChat/messages":
            if query.get("liveChatId") != "mockChat1" or "snippet" not in query.get("part", ""):
                return self.fail(400, f"bad liveChat/messages {query}")
            token = query.get("pageToken")
            if token != "api-2":
                log(f"api chat {token or 'first'}")
            return self.reply(200, api_messages(token))
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

        if url.path == "/youtubei/v1/live_chat/get_live_chat":
            if self.headers.get("Authorization"):
                log("FAIL get_live_chat carried a token")
            request = json.loads(raw) if raw else {}
            token = request.get("continuation", "")
            client = request.get("context", {}).get("client", {})
            if client.get("clientVersion") != CLIENT_VERSION or query.get("prettyPrint") != "false":
                return self.fail(400, f"bad get_live_chat request {client}")
            if token.startswith("d-top-"):
                log("FAIL the direct client asked for the top chat view")
            if token == "d-live-reload":
                log("chat direct uses the live view")
            if token in ("d-live-1", "d-live-4", "p-top-1", "p-top-3"):
                log(f"get_live_chat {token}")
            return self.reply(200, chat_continuation(token))

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
            return self.reply(200, {"id": "mockBroadcast1", "snippet": {**snippet, "liveChatId": "mockChat1"},
                                    "status": status})

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
