import SwiftUI
import UIKit
import WebKit

/// 유튜브 채팅 (P7): 로그인한 계정의 지금 방송 채팅을 받아 채팅 소스(plugins/ios-chat)에 넘기고, 옆 칸의 채팅 패널에 보인다.
///
/// 받는 길은 셋이고 앞의 것이 되면 뒤의 것은 쓰지 않는다.
/// 1. 채팅 패널(유튜브 채팅 팝업 페이지)을 열었으면 그 페이지가 받아 오는 데이터를 그대로 읽는다 (요청이 늘지 않음)
/// 2. 아니면 같은 데이터를 앱이 직접 받는다 (유튜브 웹 채팅 내부 주소, 로그인 쿠키 없이, API 할당량 없음)
/// 3. 2가 형식 변경 등으로 계속 실패하면 공식 API (liveChatMessages.list, 할당량 사용)
/// 1·2는 공식 API가 아니어서 유튜브가 형식을 바꾸면 고쳐야 한다. 어느 길이든 같은 이벤트(JSON)로 바꿔 넘기고,
/// 시청자가 쓴 내용의 정리·보안 처리는 플러그인이 한다 (chat-message.m).

// MARK: - 이벤트

/// 채팅 소스로 보내는 이벤트 하나 (ios_chat_push)
struct ChatEvent {
    enum Kind {
        case add
        /// 보여 주지 않는 항목(자리표시, 안내문). id만 기억한다
        case ignore
        case remove
        case removeAuthor
    }

    let kind: Kind
    /// add·ignore·remove는 메시지 id, removeAuthor는 채널 id
    let id: String
    var timestampUsec: Int64?
    /// add: ios_chat_push의 "add" 객체
    var json: [String: Any] = [:]
}

/// 최근 id들 (중복 거르기). 오래된 것부터 잊는다
struct RecentIDs {
    let limit: Int
    private var members: Set<String> = []
    private var order: [String] = []

    init(limit: Int) { self.limit = limit }

    func contains(_ id: String) -> Bool { members.contains(id) }

    /// 처음 보는 id면 true
    @discardableResult
    mutating func insert(_ id: String) -> Bool {
        guard members.insert(id).inserted else { return false }
        order.append(id)
        if order.count > limit {
            let dropped = order.count - limit
            order.prefix(dropped).forEach { members.remove($0) }
            order.removeFirst(dropped)
        }
        return true
    }

    mutating func removeAll() {
        members.removeAll()
        order.removeAll()
    }
}

// MARK: - 유튜브 웹 채팅 형식

/// youtube.com/live_chat 페이지(ytInitialData)와 그 페이지가 부르는 get_live_chat의 데이터.
/// 모르는 항목은 건너뛰고, 형식이 통째로 바뀌면 nil을 돌려준다.
enum YouTubeWebChat {
    struct Page {
        let clientVersion: String
        /// 채팅이 없으면 nil (꺼짐, 비공개, 끝남 등). 그때 페이지가 보이는 문장이 message
        let renderer: [String: Any]?
        let message: String?

        /// "실시간 채팅"(모든 메시지) 보기의 continuation. 없으면 페이지의 기본 보기(주요 채팅)
        var liveContinuation: String? {
            guard let renderer else { return nil }
            let header = (renderer["header"] as? [String: Any])?["liveChatHeaderRenderer"] as? [String: Any]
            let selector = (header?["viewSelector"] as? [String: Any])?["sortFilterSubMenuRenderer"] as? [String: Any]
            let items = selector?["subMenuItems"] as? [[String: Any]] ?? []
            if items.count >= 2,
                let reload = (items[1]["continuation"] as? [String: Any])?["reloadContinuationData"] as? [String: Any],
                let token = reload["continuation"] as? String
            {
                return token
            }
            return YouTubeWebChat.next(renderer)?.token
        }
    }

    static func page(_ html: String) -> Page? {
        guard let version = firstMatch(#""INNERTUBE_CLIENT_VERSION":"([^"]+)""#, in: html),
            let data = initialData(html), let contents = data["contents"] as? [String: Any]
        else { return nil }
        if let renderer = contents["liveChatRenderer"] as? [String: Any] {
            return Page(clientVersion: version, renderer: renderer, message: nil)
        }
        if let message = contents["messageRenderer"] as? [String: Any] {
            return Page(clientVersion: version, renderer: nil, message: plainText(message["text"]))
        }
        return nil
    }

    /// `window["ytInitialData"] = {...};</script>`
    private static func initialData(_ html: String) -> [String: Any]? {
        guard let start = html.range(of: #"(window\["ytInitialData"\]|var ytInitialData)\s*=\s*"#, options: .regularExpression),
            let end = html.range(of: "</script>", range: start.upperBound..<html.endIndex)
        else { return nil }
        var json = html[start.upperBound..<end.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        if json.hasSuffix(";") { json.removeLast() }
        return (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let expression = try? NSRegularExpression(pattern: pattern),
            let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
            let range = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[range])
    }

    /// get_live_chat 응답
    struct Continuation {
        let events: [ChatEvent]
        let next: String?
        let timeoutMs: Int?
        /// 보기를 바꾸거나 처음 받을 때의 전체 목록. 지난 메시지라 보여 주지 않는다
        let reload: Bool
    }

    static func continuation(_ json: [String: Any]) -> Continuation? {
        guard let contents = json["continuationContents"] as? [String: Any],
            let chat = contents["liveChatContinuation"] as? [String: Any]
        else { return nil }
        let following = Self.next(chat)
        return Continuation(
            events: events(chat["actions"]), next: following?.token, timeoutMs: following?.timeoutMs,
            reload: chat["header"] != nil || chat["itemList"] != nil)
    }

    static func next(_ chat: [String: Any]) -> (token: String, timeoutMs: Int?)? {
        for case let item as [String: Any] in chat["continuations"] as? [Any] ?? [] {
            for value in item.values {
                if let data = value as? [String: Any], let token = data["continuation"] as? String {
                    return (token, (data["timeoutMs"] as? NSNumber)?.intValue)
                }
            }
        }
        return nil
    }

    static func events(_ actions: Any?) -> [ChatEvent] {
        var result: [ChatEvent] = []
        for case let action as [String: Any] in actions as? [Any] ?? [] {
            if let item = (action["addChatItemAction"] as? [String: Any])?["item"] as? [String: Any] {
                result += items(item)
            } else if let replace = action["replaceChatItemAction"] as? [String: Any] {
                // 자리표시를 실제 메시지로 바꾼다 (보통 같은 id)
                let added = items(replace["replacementItem"] as? [String: Any] ?? [:])
                if let target = replace["targetItemId"] as? String, !added.contains(where: { $0.id == target }) {
                    result.append(ChatEvent(kind: .remove, id: target))
                }
                result += added
            } else if let target = Self.field(action, ["markChatItemAsDeletedAction", "removeChatItemAction"], "targetItemId") {
                result.append(ChatEvent(kind: .remove, id: target))
            } else if let channel = Self.field(
                action, ["markChatItemsByAuthorAsDeletedAction", "removeChatItemByAuthorAction"], "externalChannelId")
            {
                result.append(ChatEvent(kind: .removeAuthor, id: channel))
            }
        }
        return result
    }

    /// 이름이 actions 중 하나인 동작의 문자열 값
    private static func field(_ action: [String: Any], _ actions: [String], _ key: String) -> String? {
        for name in actions {
            if let value = (action[name] as? [String: Any])?[key] as? String { return value }
        }
        return nil
    }

    private static func items(_ item: [String: Any]) -> [ChatEvent] {
        var result: [ChatEvent] = []
        for (type, value) in item {
            if let renderer = value as? [String: Any], let event = message(type, renderer) { result.append(event) }
        }
        return result
    }

    private static func message(_ type: String, _ renderer: [String: Any]) -> ChatEvent? {
        guard let id = renderer["id"] as? String, !id.isEmpty else { return nil }
        var json: [String: Any] = ["type": "add", "id": id, "platform": "youtube"]
        var authorSource = renderer

        switch type {
        case "liveChatTextMessageRenderer":
            json["kind"] = "text"
            json["parts"] = parts(renderer["message"])
        case "liveChatPaidMessageRenderer":
            json["kind"] = "superchat"
            json["amount"] = plainText(renderer["purchaseAmountText"])
            json["accentColor"] = color(renderer["bodyBackgroundColor"])
            json["parts"] = parts(renderer["message"])
        case "liveChatPaidStickerRenderer":
            let accessibility = ((renderer["sticker"] as? [String: Any])?["accessibility"] as? [String: Any])?[
                "accessibilityData"] as? [String: Any]
            json["kind"] = "superchat"
            json["amount"] = plainText(renderer["purchaseAmountText"])
            json["accentColor"] = color(renderer["backgroundColor"]) ?? color(renderer["moneyChipBackgroundColor"])
            json["parts"] = [["text": accessibility?["label"] as? String ?? "슈퍼 스티커"]]
        case "liveChatMembershipItemRenderer":
            json["kind"] = "membership"
            json["parts"] = joined([
                parts(renderer["headerPrimaryText"]), parts(renderer["headerSubtext"]), parts(renderer["message"]),
            ])
        case "liveChatSponsorshipsGiftPurchaseAnnouncementRenderer":
            guard let header = (renderer["header"] as? [String: Any])?["liveChatSponsorshipsHeaderRenderer"] as? [String: Any]
            else { return ChatEvent(kind: .ignore, id: id) }
            authorSource = header
            authorSource["authorExternalChannelId"] = renderer["authorExternalChannelId"]
            json["kind"] = "membership"
            json["parts"] = parts(header["primaryText"])
        case "liveChatSponsorshipsGiftRedemptionAnnouncementRenderer":
            json["kind"] = "membership"
            json["parts"] = parts(renderer["message"])
        default:
            // 자리표시, 안내문, 모드 바뀜 등
            return ChatEvent(kind: .ignore, id: id)
        }

        author(authorSource, into: &json)
        let timestamp = (renderer["timestampUsec"] as? String).flatMap { Int64($0) }
        return ChatEvent(kind: .add, id: id, timestampUsec: timestamp, json: json)
    }

    private static func author(_ renderer: [String: Any], into json: inout [String: Any]) {
        json["author"] = plainText(renderer["authorName"]) ?? ""
        if let channel = renderer["authorExternalChannelId"] as? String { json["authorId"] = channel }

        var roles: [String] = []
        var badges: [[String: Any]] = []
        for case let item as [String: Any] in renderer["authorBadges"] as? [Any] ?? [] {
            guard let badge = item["liveChatAuthorBadgeRenderer"] as? [String: Any] else { continue }
            switch (badge["icon"] as? [String: Any])?["iconType"] as? String {
            case "OWNER": roles.append("owner")
            case "MODERATOR": roles.append("moderator")
            case "VERIFIED": roles.append("verified")
            default:
                // 멤버 배지는 채널이 정한 그림
                if let url = thumbnail(badge["customThumbnail"]) {
                    roles.append("member")
                    badges.append(["src": url, "alt": badge["tooltip"] as? String ?? ""])
                }
            }
        }
        json["roles"] = roles
        json["badges"] = badges
    }

    /// 글과 이모지. 보통 이모지는 글자로 (기기 글꼴로 그린다), 채널 맞춤 이모지는 그림으로
    static func parts(_ text: Any?) -> [[String: Any]] {
        guard let text = text as? [String: Any] else { return [] }
        if let simple = text["simpleText"] as? String { return [["text": simple]] }

        var result: [[String: Any]] = []
        for case let run as [String: Any] in text["runs"] as? [Any] ?? [] {
            if let emoji = run["emoji"] as? [String: Any] {
                let shortcut = (emoji["shortcuts"] as? [String])?.first ?? ""
                let emojiID = emoji["emojiId"] as? String ?? ""
                if emoji["isCustomEmoji"] as? Bool == true, let url = thumbnail(emoji["image"]) {
                    result.append(["src": url, "alt": shortcut.isEmpty ? emojiID : shortcut])
                } else {
                    result.append(["text": emojiID.isEmpty ? shortcut : emojiID])
                }
            } else if let string = run["text"] as? String {
                result.append(["text": string])
            }
        }
        return result
    }

    private static func joined(_ groups: [[[String: Any]]]) -> [[String: Any]] {
        var result: [[String: Any]] = []
        for group in groups where !group.isEmpty {
            if !result.isEmpty { result.append(["text": " "]) }
            result += group
        }
        return result
    }

    static func plainText(_ text: Any?) -> String? {
        guard let text = text as? [String: Any] else { return nil }
        if let simple = text["simpleText"] as? String { return simple }
        let runs = (text["runs"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }
        return runs.isEmpty ? nil : runs.joined()
    }

    /// 가장 큰 그림 주소 ("//"로 시작하면 https)
    private static func thumbnail(_ image: Any?) -> String? {
        let thumbnails = (image as? [String: Any])?["thumbnails"] as? [[String: Any]] ?? []
        guard var url = thumbnails.last?["url"] as? String else { return nil }
        if url.hasPrefix("//") { url = "https:" + url }
        return url
    }

    /// 0xAARRGGBB 정수 → "#RRGGBB"
    private static func color(_ value: Any?) -> String? {
        guard let number = value as? NSNumber else { return nil }
        return String(format: "#%06X", number.int64Value & 0xFFFFFF)
    }
}

// MARK: - 공식 API 형식

/// liveChatMessages.list의 items (https://developers.google.com/youtube/v3/live/docs/liveChatMessages)
enum YouTubeAPIChat {
    static func events(_ items: Any?) -> [ChatEvent] {
        var result: [ChatEvent] = []
        for case let item as [String: Any] in items as? [Any] ?? [] {
            guard let id = item["id"] as? String, let snippet = item["snippet"] as? [String: Any] else { continue }
            var json: [String: Any] = ["type": "add", "id": id, "platform": "youtube", "kind": "text"]
            var text = snippet["displayMessage"] as? String ?? ""

            switch snippet["type"] as? String {
            case "textMessageEvent":
                break
            case "superChatEvent":
                let details = snippet["superChatDetails"] as? [String: Any] ?? [:]
                json["kind"] = "superchat"
                json["amount"] = details["amountDisplayString"] as? String
                text = details["userComment"] as? String ?? ""
            case "superStickerEvent":
                let details = snippet["superStickerDetails"] as? [String: Any] ?? [:]
                json["kind"] = "superchat"
                json["amount"] = details["amountDisplayString"] as? String
                text = (details["superStickerMetadata"] as? [String: Any])?["altText"] as? String ?? "슈퍼 스티커"
            case "newSponsorEvent", "memberMilestoneChatEvent", "membershipGiftingEvent", "giftMembershipReceivedEvent":
                json["kind"] = "membership"
            case "messageDeletedEvent":
                if let target = (snippet["messageDeletedDetails"] as? [String: Any])?["deletedMessageId"] as? String {
                    result.append(ChatEvent(kind: .remove, id: target))
                }
                continue
            case "userBannedEvent":
                let banned = (snippet["userBannedDetails"] as? [String: Any])?["bannedUserDetails"] as? [String: Any]
                if let channel = banned?["channelId"] as? String {
                    result.append(ChatEvent(kind: .removeAuthor, id: channel))
                }
                continue
            default:
                result.append(ChatEvent(kind: .ignore, id: id))
                continue
            }

            let author = item["authorDetails"] as? [String: Any] ?? [:]
            json["author"] = author["displayName"] as? String ?? ""
            if let channel = author["channelId"] as? String { json["authorId"] = channel }
            var roles: [String] = []
            if author["isChatOwner"] as? Bool == true { roles.append("owner") }
            if author["isChatModerator"] as? Bool == true { roles.append("moderator") }
            if author["isChatSponsor"] as? Bool == true { roles.append("member") }
            if author["isVerified"] as? Bool == true { roles.append("verified") }
            json["roles"] = roles
            json["parts"] = text.isEmpty ? [] : [["text": text]]

            let timestamp = (snippet["publishedAt"] as? String).flatMap(parseDate).map {
                Int64($0.timeIntervalSince1970 * 1_000_000)
            }
            result.append(ChatEvent(kind: .add, id: id, timestampUsec: timestamp, json: json))
        }
        return result
    }

    private static func parseDate(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}

// MARK: - 받는 쪽

private func pause(_ seconds: Double) async {
    try? await Task.sleep(nanoseconds: UInt64(max(seconds, 0) * 1_000_000_000))
}

/// 유튜브 웹 채팅을 앱이 직접 받는다 (로그인 쿠키 없이). 채팅 페이지에서 continuation을 얻고 get_live_chat을 되풀이한다
final class DirectChatClient {
    enum Report {
        case receiving
        /// 페이지가 채팅을 주지 않음 (꺼짐, 비공개, 끝남 등): 페이지의 문장
        case unavailable(String)
        /// 네트워크·서버 오류
        case retrying(String)
        /// 형식이 바뀐 듯 (세 번 연속 해석 실패)
        case broken
    }

    private enum Failure: LocalizedError {
        case http(Int)
        var errorDescription: String? {
            switch self {
            case .http(let status): "HTTP \(status)"
            }
        }
    }

    static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    private let session: URLSession
    private var task: Task<Void, Never>?

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.httpAdditionalHeaders = ["User-Agent": Self.userAgent, "Accept-Language": "ko-KR,ko;q=0.9,en;q=0.8"]
        session = URLSession(configuration: configuration)
    }

    var running: Bool { task != nil }

    func start(
        videoID: String, base: URL, retryDelay: Double,
        events: @escaping @MainActor ([ChatEvent], _ history: Bool) -> Void,
        report: @escaping @MainActor (Report) -> Void
    ) {
        stop()
        appLog("chat: receiving \(videoID) directly")
        let session = session
        task = Task.detached {
            await Self.run(
                session: session, videoID: videoID, base: base, retryDelay: retryDelay, events: events, report: report)
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private static func run(
        session: URLSession, videoID: String, base: URL, retryDelay: Double,
        events: @escaping @MainActor ([ChatEvent], Bool) -> Void, report: @escaping @MainActor (Report) -> Void
    ) async {
        var failures = 0
        var backoff = 5.0

        while !Task.isCancelled {
            // 1. 채팅 페이지: 클라이언트 버전, 지난 메시지, "실시간 채팅" continuation
            var components = URLComponents(url: base.appendingPathComponent("live_chat"), resolvingAgainstBaseURL: false)!
            components.queryItems = [URLQueryItem(name: "is_popout", value: "1"), URLQueryItem(name: "v", value: videoID)]
            let page: YouTubeWebChat.Page
            do {
                let (data, response) = try await session.data(from: components.url!)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard status == 200 else { throw Failure.http(status) }
                guard let parsed = YouTubeWebChat.page(String(decoding: data, as: UTF8.self)) else {
                    failures += 1
                    appLog("chat: the live chat page has an unknown format (\(failures))")
                    if failures >= 3 { await report(.broken) }
                    await pause(retryDelay * (failures >= 3 ? 6 : 1))
                    continue
                }
                page = parsed
            } catch {
                if Task.isCancelled { return }
                await report(.retrying(error.localizedDescription))
                await pause(backoff)
                backoff = min(backoff * 2, 60)
                continue
            }

            guard let renderer = page.renderer, let token = page.liveContinuation else {
                await report(.unavailable(page.message ?? "이 방송에 채팅이 없습니다"))
                await pause(30)
                continue
            }
            backoff = 5
            await events(YouTubeWebChat.events(renderer["actions"]), true)
            await report(.receiving)

            // 2. get_live_chat을 응답이 정한 간격으로
            var continuation = token
            while !Task.isCancelled {
                do {
                    let json = try await post(session: session, base: base, version: page.clientVersion, continuation: continuation)
                    guard let result = YouTubeWebChat.continuation(json) else {
                        // 채팅이 끝났거나 형식이 바뀜: 페이지부터 다시
                        failures += 1
                        appLog("chat: get_live_chat answered without chat data (\(failures))")
                        if failures >= 3 { await report(.broken) }
                        break
                    }
                    failures = 0
                    await events(result.events, result.reload)
                    guard let next = result.next else { break }
                    continuation = next
                    await pause(Double(min(max(result.timeoutMs ?? 3000, 1000), 10000)) / 1000)
                } catch {
                    if Task.isCancelled { return }
                    await report(.retrying(error.localizedDescription))
                    await pause(backoff)
                    backoff = min(backoff * 2, 60)
                    break
                }
            }
            await pause(retryDelay)
        }
    }

    private static func post(session: URLSession, base: URL, version: String, continuation: String) async throws
        -> [String: Any]
    {
        let url = base.appendingPathComponent("youtubei/v1/live_chat/get_live_chat")
            .appending(queryItems: [URLQueryItem(name: "prettyPrint", value: "false")])
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "context": ["client": ["clientName": "WEB", "clientVersion": version, "hl": "ko", "gl": "KR"]],
            "continuation": continuation,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw Failure.http(status) }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }
}

/// 공식 API로 받는다 (웹 형식이 깨졌을 때만). liveChatMessages.list 한 번에 5 단위라 간격을 둔다
final class APIChatClient {
    enum Report {
        case receiving
        case stopped(String)
        case retrying(String)
    }

    private var task: Task<Void, Never>?

    var running: Bool { task != nil }

    func start(
        liveChatID: String, minimumInterval: Double,
        events: @escaping @MainActor ([ChatEvent], _ history: Bool) -> Void,
        report: @escaping @MainActor (Report) -> Void
    ) {
        stop()
        appLog("chat: receiving through the API")
        task = Task.detached {
            var token: String?
            var first = true
            while !Task.isCancelled {
                do {
                    var query = ["liveChatId": liveChatID, "part": "snippet,authorDetails", "maxResults": "200"]
                    if let token { query["pageToken"] = token }
                    let json = try await YouTubeAccount.shared.api("GET", "liveChat/messages", query: query)
                    if Task.isCancelled { return }
                    // 첫 응답은 지난 메시지
                    await events(YouTubeAPIChat.events(json["items"]), first)
                    first = false
                    await report(.receiving)
                    token = json["nextPageToken"] as? String ?? token
                    if json["offlineAt"] != nil {
                        await report(.stopped("방송이 끝났습니다"))
                        return
                    }
                    let interval = Double((json["pollingIntervalMillis"] as? NSNumber)?.intValue ?? 5000) / 1000
                    await pause(max(interval, minimumInterval))
                } catch {
                    if Task.isCancelled { return }
                    let message = error.localizedDescription
                    if message.contains("사용량") {
                        await report(.stopped(message))
                        return
                    }
                    await report(.retrying(message))
                    await pause(30)
                }
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }
}

// MARK: - 채팅 패널 (웹 페이지)

/// 유튜브 채팅 팝업 페이지. PC OBS의 채팅 독처럼 보고, 패널 안에서 유튜브에 로그인해 채팅도 한다.
/// 페이지가 받아 오는 채팅 데이터를 스크립트로 복사해 채팅 소스에도 쓴다. 탭을 숨겨도 창 뒤에 붙여 계속 돌린다.
///
/// 스크립트 둘: 페이지 쪽(fetch/XHR 응답과 ytInitialData를 복사해 window.postMessage)과 앱 쪽 콘텐츠 월드(그것을
/// 앱으로 넘기고, 페이지에 보이는 메시지 id를 알려 데이터가 빠지지 않는지 맞춰 본다). 앱의 메시지 처리기는 앱 쪽
/// 월드에만 있어서 페이지(그리고 Google 로그인 화면)의 스크립트에는 보이지 않는다.
@MainActor
final class ChatPanelWeb: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
    private(set) var webView: WKWebView?
    private var hiddenHost: UIView?
    /// WebKit은 패널을 처음 열 때 쓴다 (앱을 켤 때 메인 스레드를 잡지 않게)
    private lazy var world = WKContentWorld.world(name: "broadcast-chat")
    private(set) var videoID: String?
    private var base = URL(string: "https://www.youtube.com")!
    /// 지금 영상의 채팅 페이지가 떴고 채팅 데이터를 넘기기 시작했는지 (ChatFeed가 정한다)
    var ready = false
    /// CI의 mock 서버 (그 주소도 유튜브처럼 다룬다)
    var testHost: String?
    var received: ((_ kind: String, _ body: String) -> Void)?

    var chatURL: URL? {
        guard let videoID else { return nil }
        var components = URLComponents(url: base.appendingPathComponent("live_chat"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "is_popout", value: "1"), URLQueryItem(name: "dark_theme", value: "1"),
            URLQueryItem(name: "v", value: videoID),
        ]
        return components.url
    }

    func load(videoID: String, base: URL) {
        if webView != nil && self.videoID == videoID && self.base == base {
            if hiddenHost == nil && webView?.superview == nil, let webView { park(webView) }
            return
        }
        self.videoID = videoID
        self.base = base
        if webView == nil { create() }
        reload()
    }

    func reload() {
        ready = false
        if let url = chatURL { webView?.load(URLRequest(url: url)) }
    }

    func close() {
        webView?.stopLoading()
        webView?.configuration.userContentController.removeAllScriptMessageHandlers()
        webView?.removeFromSuperview()
        webView = nil
        hiddenHost?.removeFromSuperview()
        hiddenHost = nil
        videoID = nil
        ready = false
        appLog("chat panel: closed")
    }

    /// 패널의 유튜브 로그인(쿠키)을 지운다. 앱의 YouTube 계정 로그인과는 따로다
    func signOut() {
        let store = WKWebsiteDataStore.default()
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        store.fetchDataRecords(ofTypes: types) { records in
            let ours = records.filter { $0.displayName.contains("google") || $0.displayName.contains("youtube") }
            store.removeData(ofTypes: types, for: ours) {
                Task { @MainActor [weak self] in
                    appLog("chat panel: signed out (\(ours.count) site(s))")
                    self?.reload()
                }
            }
        }
    }

    func show(in container: UIView) {
        guard let webView, webView.superview !== container else { return }
        webView.frame = container.bounds
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        webView.isUserInteractionEnabled = true
        container.addSubview(webView)
        appLog("chat panel: on screen")
    }

    func hide(from container: UIView) {
        guard let webView, webView.superview === container else { return }
        park(webView)
        appLog("chat panel: behind the window")
    }

    /// 창 맨 뒤 (그려지지만 보이지 않음): 탭을 숨겨도 페이지가 멈추지 않게
    private func park(_ webView: WKWebView) {
        guard let window = Self.window() else {
            webView.removeFromSuperview()
            return
        }
        if hiddenHost?.window == nil {
            hiddenHost?.removeFromSuperview()
            let host = UIView(frame: CGRect(x: 0, y: 0, width: 360, height: 640))
            host.isUserInteractionEnabled = false
            host.clipsToBounds = true
            window.insertSubview(host, at: 0)
            hiddenHost = host
        }
        webView.frame = hiddenHost!.bounds
        hiddenHost!.addSubview(webView)
    }

    private static func window() -> UIWindow? {
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            if let window = scene.keyWindow ?? scene.windows.first { return window }
        }
        return nil
    }

    private func create() {
        let configuration = WKWebViewConfiguration()
        // 패널에서 한 유튜브 로그인은 남긴다
        configuration.websiteDataStore = .default()
        // Safari와 같은 이름 (앱 안 웹 화면이라고 Google 로그인을 막지 않게)
        let major = UIDevice.current.systemVersion.split(separator: ".").first ?? "18"
        configuration.applicationNameForUserAgent = "Version/\(major).0 Safari/605.1.15"
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        configuration.dataDetectorTypes = []

        let content = configuration.userContentController
        content.addUserScript(
            WKUserScript(source: Self.pageScript, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
        content.addUserScript(
            WKUserScript(source: Self.bridgeScript, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: world))
        content.add(WeakMessageHandler(self), contentWorld: world, name: "broadcastChat")

        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 360, height: 640), configuration: configuration)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.backgroundColor = .black
        self.webView = webView
        park(webView)
        appLog("chat panel: created")
    }

    // MARK: 받기

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.webView === webView, message.frameInfo.isMainFrame,
            isOurs(message.frameInfo.securityOrigin.host),
            let body = message.body as? [String: Any], let kind = body["kind"] as? String,
            let text = body["body"] as? String
        else { return }
        received?(kind, text)
    }

    // MARK: 이동 제한

    private func isOurs(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        if let testHost, host == testHost { return true }
        return host == "youtube.com" || host.hasSuffix(".youtube.com")
    }

    /// 패널 안에서 열어도 되는 곳: 유튜브와 Google 로그인
    private func isAllowed(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        if isOurs(host) { return true }
        return host.range(of: #"(^|\.)google\.(com|co\.[a-z]{2}|com\.[a-z]{2}|[a-z]{2})$"#, options: .regularExpression)
            != nil
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async
        -> WKNavigationActionPolicy
    {
        guard let url = navigationAction.request.url else { return .cancel }
        // .allow면 WebKit이 유니버설 링크를 맡은 앱으로 넘길 수 있다: Google 로그인을 마치고 youtube.com/signin으로
        // 갈 때 유튜브 앱이 열리고 패널은 빈 화면으로 남았다 (기기 시험). 패널 안에서만 연다
        // 페이지 안의 틀(로그인 화면의 보안 확인 등)은 막지 않는다
        if navigationAction.targetFrame?.isMainFrame != true { return .allowWithoutTryingAppLink }
        if isAllowed(url.host) {
            if !url.path.hasPrefix("/live_chat") {
                // 로그인 흐름을 볼 수 있게 (쿼리에는 로그인 정보가 있을 수 있어 뺀다)
                appLog("chat panel: open \(url.host ?? "")\(url.path)")
            }
            return .allowWithoutTryingAppLink
        }
        if navigationAction.navigationType == .linkActivated, ["http", "https"].contains(url.scheme ?? "") {
            // 채팅 속 링크는 Safari로 (기다리지 않는다)
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
        } else {
            appLog("chat panel: kept out \(url.scheme ?? "?")://\(url.host ?? "")")
        }
        return .cancel
    }

    func webView(
        _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if let url = navigationAction.request.url {
            if isAllowed(url.host) {
                webView.load(navigationAction.request)
            } else if ["http", "https"].contains(url.scheme ?? "") {
                UIApplication.shared.open(url)
            }
        }
        return nil
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        ready = false
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let url = webView.url, let host = url.host?.lowercased() else { return }
        // 로그인을 마치고 유튜브 첫 화면 등으로 오면 채팅으로 돌아간다
        if isOurs(host) && !host.hasPrefix("accounts.") && !host.hasPrefix("consent.") && !url.path.hasPrefix("/live_chat")
        {
            appLog("chat panel: back to the chat from \(url.path)")
            reload()
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        appLog("chat panel: could not open the page (\(error.localizedDescription))")
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        appLog("chat panel: web content process ended, reloading")
        reload()
    }

    // MARK: 스크립트

    /// 페이지 쪽: 채팅 데이터 응답을 복사한다. 페이지의 동작은 바꾸지 않는다
    private static let pageScript = #"""
        (() => {
          'use strict';
          if (!location.pathname.startsWith('/live_chat')) return;
          const post = (kind, body) => {
            try { window.postMessage({__broadcastChat: kind, body: body}, location.origin); } catch (e) {}
          };
          const isChat = (url) => typeof url === 'string' && url.indexOf('/youtubei/v1/live_chat/get_live_chat') !== -1;

          const originalFetch = window.fetch;
          if (typeof originalFetch === 'function') {
            window.fetch = function (input, init) {
              const result = originalFetch.apply(this, arguments);
              try {
                const url = typeof input === 'string' ? input : (input && input.url) || String(input);
                if (isChat(url)) {
                  result.then((response) => response.clone().text()).then((text) => post('continuation', text), () => {});
                }
              } catch (e) {}
              return result;
            };
          }

          const open = XMLHttpRequest.prototype.open;
          XMLHttpRequest.prototype.open = function (method, url) {
            try {
              if (isChat(String(url))) {
                this.addEventListener('load', () => {
                  try { post('continuation', String(this.responseText)); } catch (e) {}
                });
              }
            } catch (e) {}
            return open.apply(this, arguments);
          };

          document.addEventListener('DOMContentLoaded', () => {
            try {
              const data = window.ytInitialData;
              const renderer = data && data.contents && data.contents.liveChatRenderer;
              post('initial', JSON.stringify({chat: !!renderer, actions: (renderer && renderer.actions) || []}));
            } catch (e) {}
          });
        })();
        """#

    /// 앱 쪽 월드: 페이지 쪽이 보낸 것을 앱으로, 그리고 화면에 나온 메시지 id
    private static let bridgeScript = #"""
        (() => {
          'use strict';
          if (!location.pathname.startsWith('/live_chat')) return;
          const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.broadcastChat;
          if (!handler) return;

          window.addEventListener('message', (event) => {
            const data = event.data;
            if (event.source !== window || !data || typeof data.__broadcastChat !== 'string' ||
                typeof data.body !== 'string' || data.body.length > 8000000) return;
            handler.postMessage({kind: data.__broadcastChat, body: data.body});
          });

          const tags = new Set(['YT-LIVE-CHAT-TEXT-MESSAGE-RENDERER', 'YT-LIVE-CHAT-PAID-MESSAGE-RENDERER',
                                'YT-LIVE-CHAT-PAID-STICKER-RENDERER', 'YT-LIVE-CHAT-MEMBERSHIP-ITEM-RENDERER']);
          let shown = [];
          const observer = new MutationObserver((records) => {
            for (const record of records) {
              for (const node of record.addedNodes) {
                if (node.nodeType === 1 && tags.has(node.tagName) && node.id) shown.push(node.id);
              }
            }
          });
          const watch = () => observer.observe(document.documentElement, {childList: true, subtree: true});
          if (document.documentElement) watch(); else document.addEventListener('DOMContentLoaded', watch);
          setInterval(() => {
            if (shown.length) {
              handler.postMessage({kind: 'dom', body: JSON.stringify(shown.slice(0, 200))});
              shown = [];
            }
          }, 2000);
        })();
        """#
}

/// WKUserContentController가 처리기를 강하게 잡아서 패널을 놓아주지 않으므로 약하게 잡는다
@MainActor
private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: (any WKScriptMessageHandler)?

    init(_ target: any WKScriptMessageHandler) { self.target = target }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}

// MARK: - 받는 길 고르기

@MainActor
final class ChatFeed: ObservableObject {
    static let shared = ChatFeed()

    enum Source: String {
        case none, panel, direct, api
    }

    @Published private(set) var status = ""
    @Published private(set) var source = Source.none
    @Published private(set) var videoID: String?
    /// 패널을 열었는지. 연 뒤로는 탭을 숨겨도 페이지를 유지한다 (닫기를 누를 때까지)
    @Published private(set) var panelOpened = false

    let panel = ChatPanelWeb()

    private var webBase = URL(string: "https://www.youtube.com")!
    private let direct = DirectChatClient()
    private let api = APIChatClient()
    private var directReport: DirectChatClient.Report?
    private var apiReport: APIChatClient.Report?
    /// 웹 형식이 깨져 공식 API로 받는 중 (이 방송 동안)
    private var webBroken = false
    /// 패널 페이지에 보인 메시지가 데이터로 오지 않음 (페이지가 바뀌어 복사가 안 되는 듯) → 직접 받는다
    private var panelBroken = false

    /// 채팅 소스로 보낸 것 (중복 거르기), 데이터로 본 모든 항목 (패널 화면과 맞춰 보기)
    private var shown = RecentIDs(limit: 5000)
    private var known = RecentIDs(limit: 5000)
    private var domPending: [String: Date] = [:]
    private var domMissing = 0
    /// 이보다 오래된 메시지는 지난 것이라 보여 주지 않는다 (마이크로초)
    private var displayFrom: Int64 = 0

    private var lastLookup: Date?
    private var lookingUp = false
    private var timer: Timer?
    private var pushed = 0
    private var removed = 0
    private var nextLog = 1

    private var retryDelay = 10.0
    private var minimumAPIInterval = 5.0
    /// CI: 보낸 메시지 id
    private var autotestIDs: [String]?

    private init() {
        let started = Date()
        defer { appLog(String(format: "chat: feed ready in %.0f ms", Date().timeIntervalSince(started) * 1000)) }
        // CI는 처음부터 mock 서버로 (진짜 유튜브에 요청하지 않게)
        let args = ProcessInfo.processInfo.arguments
        if let index = args.firstIndex(of: "-autotest-chat"), index + 1 < args.count, let base = URL(string: args[index + 1]) {
            webBase = base
            panel.testHost = base.host
            retryDelay = 2
            minimumAPIInterval = 1
            autotestIDs = []
        }
        panel.received = { [weak self] kind, body in self?.panelData(kind: kind, body: body) }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    // MARK: 패널

    /// 옆 칸의 채팅 탭이 보일 때
    func openPanel() {
        if !panelOpened {
            panelOpened = true
            appLog("chat panel: opened")
        }
        tick()
    }

    /// 패널 페이지를 닫는다 (메모리를 덜 쓰게). 채팅 소스가 있으면 직접 받기로 돌아간다
    func closePanel() {
        panelOpened = false
        panel.close()
        tick()
    }

    func reloadPanel() {
        lastLookup = nil
        panelBroken = false
        domMissing = 0
        domPending.removeAll()
        panel.reload()
        tick()
    }

    // MARK: 고르기

    func tick() {
        guard Core.shared.isRunning else { return }
        let account = YouTubeAccount.shared
        guard account.loggedIn else {
            stopReceiving()
            if videoID != nil { videoID = nil }
            update("YouTube 계정으로 로그인하면 채팅을 받습니다 (설정 › 송출 › 방식 › YouTube 계정)", .none)
            return
        }
        if let id = account.broadcastID, id != videoID { switchVideo(to: id) }

        guard core_chat_listeners() > 0 || panelOpened else {
            stopReceiving()
            update("채팅 소스를 넣거나 채팅 패널을 열면 받습니다", .none)
            return
        }

        let streaming = Outputs.shared.stats.streaming
        guard let videoID else {
            stopReceiving()
            lookUpBroadcast(streaming: streaming)
            update(streaming ? "진행 중인 방송을 찾는 중…" : "송출을 시작하면 이 방송의 채팅을 받습니다", .none)
            return
        }

        if panelOpened {
            panel.load(videoID: videoID, base: webBase)
            checkPanel()
            if panel.ready && !panelBroken {
                stopReceiving()
                update("채팅 패널에서 받는 중 · 방송 화면에도 패널의 보기(주요/실시간 채팅)가 적용됩니다", .panel)
                return
            }
        }

        if webBroken, let chatID = account.liveChatID, account.broadcastID == videoID {
            direct.stop()
            if !api.running {
                apiReport = nil
                api.start(
                    liveChatID: chatID, minimumInterval: minimumAPIInterval,
                    events: { [weak self] events, history in self?.receive(events, history: history, from: .api) },
                    report: { [weak self] report in self?.apiReported(report) })
            }
            update(apiStatus, .api)
        } else {
            api.stop()
            if !direct.running {
                directReport = nil
                direct.start(
                    videoID: videoID, base: webBase, retryDelay: retryDelay,
                    events: { [weak self] events, history in self?.receive(events, history: history, from: .direct) },
                    report: { [weak self] report in self?.directReported(report) })
            }
            update(directStatus, .direct)
            // 채팅이 없다고 나오면 다른 방송으로 송출 중일 수 있다
            if streaming, case .unavailable = directReport { lookUpBroadcast(streaming: true) }
        }
    }

    private var directStatus: String {
        switch directReport {
        case .receiving: "직접 받는 중 (YouTube 웹 채팅, API 할당량 쓰지 않음)"
        case .unavailable(let message): "채팅을 받을 수 없습니다: \(message)"
        case .retrying(let message): "연결 오류, 다시 시도하는 중… (\(message))"
        case .broken: "YouTube 웹 채팅 형식이 바뀐 것 같습니다. 앱을 고쳐야 합니다"
        case nil: "채팅에 연결하는 중…"
        }
    }

    private var apiStatus: String {
        switch apiReport {
        case .receiving: "공식 API로 받는 중 (웹 채팅을 읽지 못해서, API 할당량 사용)"
        case .stopped(let message): "공식 API 받기 멈춤: \(message)"
        case .retrying(let message): "공식 API 오류, 다시 시도하는 중… (\(message))"
        case nil: "공식 API에 연결하는 중…"
        }
    }

    private func directReported(_ report: DirectChatClient.Report) {
        directReport = report
        if case .broken = report, !webBroken {
            webBroken = true
            appLog("chat: the web chat format looks changed, using the API if possible")
        }
        tick()
    }

    private func apiReported(_ report: APIChatClient.Report) {
        apiReport = report
        tick()
    }

    private func update(_ text: String, _ newSource: Source) {
        if source != newSource {
            source = newSource
            appLog("chat: source \(newSource.rawValue)")
        }
        if status != text {
            status = text
            core_chat_set_status(text)
        }
    }

    private func stopReceiving() {
        direct.stop()
        api.stop()
        directReport = nil
        apiReport = nil
    }

    private func switchVideo(to id: String) {
        appLog("chat: broadcast \(id)")
        videoID = id
        webBroken = false
        panelBroken = false
        domMissing = 0
        domPending.removeAll()
        shown.removeAll()
        known.removeAll()
        displayFrom = Int64(Date().timeIntervalSince1970 * 1_000_000) - 10_000_000
        stopReceiving()
    }

    /// 지금 진행 중인 방송 찾기 (API 1 단위): 송출 중이 아니면 한 번만, 송출 중이면 1분마다
    private func lookUpBroadcast(streaming: Bool) {
        guard !lookingUp else { return }
        if let lastLookup, !streaming || Date().timeIntervalSince(lastLookup) < 60 { return }
        lastLookup = Date()
        lookingUp = true
        Task {
            do {
                try await YouTubeAccount.shared.findActiveBroadcast()
            } catch {
                appLog("chat: broadcast lookup failed: \(error.localizedDescription)")
            }
            lookingUp = false
            tick()
        }
    }

    // MARK: 받은 것

    private func panelData(kind: String, body: String) {
        switch kind {
        case "initial":
            guard let json = Self.object(body) else { return }
            receive(YouTubeWebChat.events(json["actions"]), history: true, from: .panel)
            panel.ready = json["chat"] as? Bool == true
            if panel.ready { appLog("chat panel: receiving from the page") }
            tick()
        case "continuation":
            guard let json = Self.object(body), let result = YouTubeWebChat.continuation(json) else { return }
            receive(result.events, history: result.reload, from: .panel)
        case "dom":
            guard let ids = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String] else { return }
            let now = Date()
            for id in ids where !known.contains(id) && domPending[id] == nil {
                domPending[id] = now
            }
        default:
            break
        }
    }

    /// 페이지에 보였는데 10초가 지나도 데이터로 오지 않은 메시지가 셋을 넘으면 패널 데이터는 믿지 않는다
    private func checkPanel() {
        let now = Date()
        let late = domPending.filter { now.timeIntervalSince($0.value) > 10 }
        guard !late.isEmpty else { return }
        late.keys.forEach { domPending[$0] = nil }
        domMissing += late.count
        if domMissing >= 3 && !panelBroken {
            panelBroken = true
            appLog("chat: the panel showed \(domMissing) message(s) its data did not carry, receiving directly")
        }
    }

    private func receive(_ events: [ChatEvent], history: Bool, from origin: Source) {
        // 멈춘 길에서 늦게 온 것은 버린다 (패널은 늘 받는다: 중복은 아래에서 거른다)
        guard origin == .panel || origin == source else { return }

        var out: [[String: Any]] = []
        var added = 0
        for event in events {
            switch event.kind {
            case .add:
                known.insert(event.id)
                domPending[event.id] = nil
                guard shown.insert(event.id) else { continue }
                if history || (event.timestampUsec ?? .max) < displayFrom { continue }
                out.append(event.json)
                added += 1
                autotestIDs?.append(event.id)
            case .ignore:
                known.insert(event.id)
                domPending[event.id] = nil
            case .remove:
                out.append(["type": "remove", "id": event.id])
            case .removeAuthor:
                out.append(["type": "removeAuthor", "authorId": event.id])
            }
        }
        guard !out.isEmpty, let data = try? JSONSerialization.data(withJSONObject: out),
            let json = String(data: data, encoding: .utf8)
        else { return }
        core_chat_push(json)

        pushed += added
        removed += out.count - added
        if pushed >= nextLog || out.count > added {
            if pushed >= nextLog { nextLog = (pushed / 50 + 1) * 50 }
            appLog("chat: sent \(pushed) message(s), \(removed) removal(s) (\(origin.rawValue))")
        }
    }

    private static func object(_ text: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
    }

    // MARK: CI

    /// CI (`-autotest-chat <mock 주소>`, YouTube 로그인 시험 뒤): 직접 받기 → 패널 → (웹 형식이 깨지면) 공식 API 순서로
    /// 메시지와 삭제가 채팅 소스까지 가는지 본다. mock(ios/scripts/youtube-mock.py)이 단계마다 다른 응답을 준다:
    /// 메시지 id가 d-(직접) p-(패널) a-(API)로 시작하고, hist-·old-는 지난 메시지라 보내면 안 된다.
    func runAutotest() async {
        guard autotestIDs != nil else { return }
        appLog("chat autotest: start")

        func count(_ prefix: String) -> Int { (autotestIDs ?? []).filter { $0.hasPrefix(prefix) }.count }
        func wait(_ seconds: Double, until condition: () -> Bool) async -> Bool {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline {
                if condition() { return true }
                await pause(0.5)
            }
            return condition()
        }

        tick()
        let directOK = await wait(30) { source == .direct && count("d-") >= 5 && removed >= 2 }
        appLog("chat autotest: direct \(directOK ? "ok" : "failed") (sent \(count("d-")), removals \(removed))")

        // 사용자가 옆 칸의 채팅 탭을 누른 것처럼 (탭 화면이 패널을 열고 웹 화면을 붙인다)
        UserDefaults.standard.set("chat", forKey: "sideColumnTab")
        openPanel()
        let removedBefore = removed
        let panelOK = await wait(30) { source == .panel && count("p-") >= 2 && removed > removedBefore }
        appLog("chat autotest: panel \(panelOK ? "ok" : "failed") (sent \(count("p-")), source \(source.rawValue))")

        // 패널을 닫으면 직접 받기로 돌아가는데, mock은 이제 형식이 바뀐 페이지를 준다 → 공식 API
        UserDefaults.standard.set("sources", forKey: "sideColumnTab")
        closePanel()
        let apiOK = await wait(45) { source == .api && count("a-") >= 2 }
        appLog("chat autotest: api \(apiOK ? "ok" : "failed") (sent \(count("a-")), source \(source.rawValue))")

        let ids = autotestIDs ?? []
        let history = ids.filter { $0.hasPrefix("hist-") || $0.hasPrefix("old-") }.count
        let duplicates = ids.count - Set(ids).count
        appLog(
            "chat autotest: \(directOK && panelOK && apiOK && history == 0 && duplicates == 0 ? "ok" : "failed") "
                + "(history shown \(history), duplicates \(duplicates))")

        // 끝으로 채팅 탭을 다시 띄워 둔다: CI가 패널 화면을 찍고, 다시 띄운 실행(로그인 없음)은 안내 화면을 보인다
        UserDefaults.standard.set("chat", forKey: "sideColumnTab")
        openPanel()
        _ = await wait(15) { source == .panel }
        appLog("chat autotest: done (panel tab \(source == .panel ? "receiving" : "not ready"))")
    }
}

// MARK: - 패널 화면

/// 옆 칸의 "채팅" 탭
struct ChatPanelView: View {
    @ObservedObject var feed: ChatFeed
    @ObservedObject private var account = YouTubeAccount.shared
    var close: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 8) {
                Text(feed.status.isEmpty ? "채팅" : feed.status)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Menu {
                    Button("다시 불러오기", systemImage: "arrow.clockwise") { feed.reloadPanel() }
                    Button("패널의 YouTube 로그아웃", systemImage: "rectangle.portrait.and.arrow.right") {
                        feed.panel.signOut()
                    }
                    Button("패널 닫기", systemImage: "xmark") {
                        feed.closePanel()
                        close()
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 6)

            if !account.loggedIn {
                placeholder("YouTube 계정으로 로그인하면 내 방송의 채팅이 여기에 나옵니다.", "설정 › 송출 › 방식에서 YouTube 계정을 고르세요.")
            } else if feed.videoID == nil {
                placeholder("송출을 시작하면 이 방송의 채팅이 여기에 나옵니다.", "패널 안에서 YouTube에 로그인하면 채팅도 쓸 수 있습니다.")
            } else {
                ChatWebViewHost(panel: feed.panel)
            }
        }
        .onAppear { feed.openPanel() }
    }

    private func placeholder(_ title: String, _ detail: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "bubble.left.and.text.bubble.right").font(.system(size: 32))
            Text(title).font(.headline).multilineTextAlignment(.center)
            Text(detail).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 패널의 웹 화면을 이 자리에 붙이고, 사라지면 창 뒤로 돌려놓는다 (페이지는 계속 돈다)
struct ChatWebViewHost: UIViewRepresentable {
    let panel: ChatPanelWeb

    func makeCoordinator() -> ChatPanelWeb { panel }

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .black
        panel.show(in: container)
        return container
    }

    func updateUIView(_ container: UIView, context: Context) {
        // 웹 화면이 이 뒤에 만들어졌을 수 있다
        panel.show(in: container)
    }

    static func dismantleUIView(_ container: UIView, coordinator: ChatPanelWeb) {
        coordinator.hide(from: container)
    }
}
