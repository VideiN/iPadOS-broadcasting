import CoreImage
import CoreImage.CIFilterBuiltins
import Network
import SwiftUI
import UIKit
import simd

/// 얼굴 추적 받기 (P9, docs/face-link.md의 FaceLink v1): 아이폰 컴패니언 앱이 같은 Wi-Fi에서 UDP로 보내는 얼굴 수치
/// (블렌드셰이프 52개, 머리·눈 자세)를 받는다. 메시지는 VMC 프로토콜(OSC) 그대로라 다른 VMC 앱도 설정으로 받을 수 있다.
/// 받은 값은 FaceFrame으로 두고, 아바타 소스(다음 단계)가 latestFrame()으로 읽는다.

// MARK: - 받은 값

/// ARKit 블렌드셰이프 52개. 보내는 이름은 대문자로 시작하는 "Perfect Sync" 표기 (문서 부록 A)
enum FaceBlendShape {
    static let names = [
        "EyeBlinkLeft", "EyeLookDownLeft", "EyeLookInLeft", "EyeLookOutLeft", "EyeLookUpLeft", "EyeSquintLeft",
        "EyeWideLeft",
        "EyeBlinkRight", "EyeLookDownRight", "EyeLookInRight", "EyeLookOutRight", "EyeLookUpRight", "EyeSquintRight",
        "EyeWideRight",
        "JawForward", "JawLeft", "JawRight", "JawOpen",
        "MouthClose", "MouthFunnel", "MouthPucker", "MouthLeft", "MouthRight", "MouthSmileLeft", "MouthSmileRight",
        "MouthFrownLeft", "MouthFrownRight", "MouthDimpleLeft", "MouthDimpleRight", "MouthStretchLeft",
        "MouthStretchRight", "MouthRollLower", "MouthRollUpper", "MouthShrugLower", "MouthShrugUpper", "MouthPressLeft",
        "MouthPressRight", "MouthLowerDownLeft", "MouthLowerDownRight", "MouthUpperUpLeft", "MouthUpperUpRight",
        "BrowDownLeft", "BrowDownRight", "BrowInnerUp", "BrowOuterUpLeft", "BrowOuterUpRight",
        "CheekPuff", "CheekSquintLeft", "CheekSquintRight", "NoseSneerLeft", "NoseSneerRight",
        "TongueOut",
    ]

    /// 소문자 이름 → 번호. Perfect Sync 표기와 ARKit 원래 문자열(eyeBlink_L 등)을 모두 받는다
    private static let indices: [String: Int] = {
        var result: [String: Int] = [:]
        for (index, name) in names.enumerated() {
            result[name.lowercased()] = index
            result[arkitName(name).lowercased()] = index
        }
        return result
    }()

    static func index(_ name: String) -> Int? { indices[name.lowercased()] }

    /// EyeBlinkLeft → eyeBlink_L. JawLeft·MouthLeft 같은 방향 이름은 그대로 (ARKit도 jawLeft)
    private static func arkitName(_ name: String) -> String {
        let result = name.prefix(1).lowercased() + String(name.dropFirst())
        let directions: Set<String> = ["JawLeft", "JawRight", "MouthLeft", "MouthRight"]
        guard !directions.contains(name) else { return result }
        if result.hasSuffix("Left") { return String(result.dropLast(4)) + "_L" }
        if result.hasSuffix("Right") { return String(result.dropLast(5)) + "_R" }
        return result
    }
}

/// 한 프레임의 얼굴 수치. 좌표는 VMC(Unity) 기준: 왼손 좌표계, +Y 위, +Z 앞, 미터. 머리 자세는 보내는 쪽에서 정면 보정한 값
struct FaceFrame {
    var sequence: Int32 = 0
    /// 보내는 쪽 세션 시작부터 초
    var sentTime: Float = 0
    var tracking = true
    /// 받은 시각 (systemUptime)
    var receivedAt: TimeInterval = 0
    var blendShapes = [Float](repeating: 0, count: FaceBlendShape.names.count)
    /// 한 번이라도 받은 블렌드셰이프 (비트마다 하나)
    var present: UInt64 = 0
    var headPosition = SIMD3<Float>(0, 0, 0)
    var headRotation = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
    var leftEye: simd_quatf?
    var rightEye: simd_quatf?

    var presentCount: Int { present.nonzeroBitCount }

    func value(_ name: String) -> Float {
        FaceBlendShape.index(name).map { blendShapes[$0] } ?? 0
    }
}

// MARK: - OSC

/// OSC 1.0의 필요한 만큼: 메시지·번들 읽기와 메시지 쓰기. 받는 패킷은 남이 보낸 것이므로 길이를 모두 확인한다
enum OSC {
    enum Value {
        case int(Int32)
        case float(Float)
        case string(String)
        case other
    }

    struct Message {
        let address: String
        let values: [Value]

        func string(_ index: Int) -> String? {
            guard index < values.count, case .string(let value) = values[index] else { return nil }
            return value
        }

        func float(_ index: Int) -> Float? {
            guard index < values.count, case .float(let value) = values[index], value.isFinite else { return nil }
            return value
        }

        func int(_ index: Int) -> Int32? {
            guard index < values.count, case .int(let value) = values[index] else { return nil }
            return value
        }
    }

    private static let bundleTag = Array("#bundle".utf8) + [0]
    /// 한 패킷 안의 메시지 수 상한 (블렌드셰이프 52개 + 자세 + 머리글이면 60개쯤)
    private static let maxMessages = 512

    /// 패킷 하나를 메시지들로. 형식이 틀리면 nil
    static func decode(_ bytes: [UInt8]) -> [Message]? {
        var messages: [Message] = []
        guard decodePacket(bytes[...], depth: 0, into: &messages) else { return nil }
        return messages
    }

    private static func decodePacket(_ bytes: ArraySlice<UInt8>, depth: Int, into messages: inout [Message]) -> Bool {
        if bytes.starts(with: bundleTag) {
            // "#bundle\0" + time tag 8바이트 + (크기 4바이트 + 내용)들
            guard depth < 4, bytes.count >= 16 else { return false }
            var index = bytes.startIndex + 16
            while index < bytes.endIndex {
                guard let size = int32(bytes, index), size >= 0, size % 4 == 0,
                    index + 4 + Int(size) <= bytes.endIndex
                else { return false }
                let element = bytes[(index + 4)..<(index + 4 + Int(size))]
                guard decodePacket(element, depth: depth + 1, into: &messages), messages.count <= maxMessages else {
                    return false
                }
                index += 4 + Int(size)
            }
            return true
        }
        guard let message = decodeMessage(bytes) else { return false }
        messages.append(message)
        return messages.count <= maxMessages
    }

    private static func decodeMessage(_ bytes: ArraySlice<UInt8>) -> Message? {
        var index = bytes.startIndex
        guard let address = string(bytes, &index), address.hasPrefix("/") else { return nil }
        // 옛 OSC는 타입 태그가 없을 수 있다: 인자 없음
        guard index < bytes.endIndex else { return Message(address: address, values: []) }
        guard let tags = string(bytes, &index), tags.hasPrefix(",") else { return nil }

        var values: [Value] = []
        for tag in tags.utf8.dropFirst() {
            switch tag {
            case UInt8(ascii: "i"):
                guard let value = int32(bytes, index) else { return nil }
                values.append(.int(value))
                index += 4
            case UInt8(ascii: "f"):
                guard let value = int32(bytes, index) else { return nil }
                values.append(.float(Float(bitPattern: UInt32(bitPattern: value))))
                index += 4
            case UInt8(ascii: "s"), UInt8(ascii: "S"):
                guard let value = string(bytes, &index) else { return nil }
                values.append(.string(value))
            case UInt8(ascii: "b"):
                guard let size = int32(bytes, index), size >= 0 else { return nil }
                let padded = (Int(size) + 3) / 4 * 4
                guard index + 4 + padded <= bytes.endIndex else { return nil }
                values.append(.other)
                index += 4 + padded
            case UInt8(ascii: "h"), UInt8(ascii: "t"), UInt8(ascii: "d"):
                guard index + 8 <= bytes.endIndex else { return nil }
                values.append(.other)
                index += 8
            case UInt8(ascii: "c"), UInt8(ascii: "r"), UInt8(ascii: "m"):
                guard index + 4 <= bytes.endIndex else { return nil }
                values.append(.other)
                index += 4
            case UInt8(ascii: "T"), UInt8(ascii: "F"), UInt8(ascii: "N"), UInt8(ascii: "I"):
                values.append(.other)
            default:
                return nil
            }
        }
        return Message(address: address, values: values)
    }

    /// 0으로 끝나고 4바이트로 채운 UTF-8 문자열
    private static func string(_ bytes: ArraySlice<UInt8>, _ index: inout Int) -> String? {
        guard index < bytes.endIndex, let end = bytes[index...].firstIndex(of: 0),
            let value = String(bytes: bytes[index..<end], encoding: .utf8)
        else { return nil }
        let length = (end - index + 4) / 4 * 4
        guard index + length <= bytes.endIndex else { return nil }
        index += length
        return value
    }

    private static func int32(_ bytes: ArraySlice<UInt8>, _ index: Int) -> Int32? {
        guard index >= bytes.startIndex, index + 4 <= bytes.endIndex else { return nil }
        let value =
            UInt32(bytes[index]) << 24 | UInt32(bytes[index + 1]) << 16 | UInt32(bytes[index + 2]) << 8
            | UInt32(bytes[index + 3])
        return Int32(bitPattern: value)
    }

    static func encode(_ address: String, _ values: [Value]) -> Data {
        var out: [UInt8] = []
        func appendString(_ text: String) {
            out += Array(text.utf8) + [0]
            while out.count % 4 != 0 { out.append(0) }
        }
        func appendInt(_ value: UInt32) {
            out += [UInt8(value >> 24), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
        }
        appendString(address)
        var tags = ","
        for value in values {
            switch value {
            case .int: tags += "i"
            case .float: tags += "f"
            case .string: tags += "s"
            case .other: break
            }
        }
        appendString(tags)
        for value in values {
            switch value {
            case .int(let number): appendInt(UInt32(bitPattern: number))
            case .float(let number): appendInt(number.bitPattern)
            case .string(let text): appendString(text)
            case .other: break
            }
        }
        return Data(out)
    }
}

// MARK: - 받는 쪽 (네트워크 스레드)

/// 받는 쪽 상태 (화면과 CI가 본다)
struct FaceLinkStatus: Equatable {
    enum State: String {
        case off, waiting, receiving, faceLost, disconnected
    }

    var state = State.off
    var port: UInt16 = 0
    var listening = false
    var error: String?
    /// Bonjour로 알린 이름. nil이면 못 알림 (QR·주소로 연결)
    var advertised: String?
    var senderName: String?
    var senderAddress: String?
    var senderApp: String?
    /// FaceLink Hello 없이 VMC만 보내는 앱
    var senderIsVMC = false
    var fps = 0.0
    var lastSequence: Int32 = 0
    var frames = 0
    /// 다른 보내는 쪽(토큰이 틀리거나 허락하지 않은 VMC)에서 와서 버린 패킷
    var ignored = 0
    /// OSC로 읽을 수 없거나 너무 큰 패킷
    var invalid = 0
    /// 순번이 지난 것이라 버린 프레임
    var stale = 0
    var trackingLostFrames = 0
    var disconnects = 0
}

/// UDP 받기. 모든 일은 자기 큐에서 하고, 최신 프레임과 상태만 잠금으로 내놓는다
final class FaceLinkEngine: @unchecked Sendable {
    struct Config: Equatable {
        var port: UInt16
        var token: String
        var acceptVMC: Bool
        var name: String
    }

    private final class Peer {
        let connection: NWConnection
        let address: String
        var lastPacket: TimeInterval = 0
        var helloName: String?
        var helloApp: String?
        var session: String?
        var lastSequence: Int32?
        /// 조립 중인 프레임. stale이면 Apply를 만나도 버린다
        var pending: FaceFrame?
        var pendingStale = false
        var warnedToken = false

        init(_ connection: NWConnection) {
            self.connection = connection
            if case .hostPort(let host, let port) = connection.endpoint {
                address = "\(host):\(port)"
            } else {
                address = "\(connection.endpoint)"
            }
        }
    }

    private let queue = DispatchQueue(label: "facelink", qos: .userInteractive)
    private let lock = NSLock()
    private var sharedStatus = FaceLinkStatus()
    private var sharedFrame: FaceFrame?

    // 아래는 큐에서만
    private var config: Config?
    private var listener: NWListener?
    private var advertise = true
    private var peers: [NWEndpoint: Peer] = [:]
    private var active: Peer?
    private var lastFrame = FaceFrame()
    private var lastFrameTime: TimeInterval = 0
    private var frameTimes: [TimeInterval] = []
    private var timer: DispatchSourceTimer?
    private var restart: DispatchWorkItem?
    private var lostLogged = false
    private var disconnectedLogged = false
    private var nextLog: TimeInterval = 0

    // MARK: 밖에서

    func status() -> FaceLinkStatus {
        lock.lock()
        defer { lock.unlock() }
        return sharedStatus
    }

    func latestFrame() -> FaceFrame? {
        lock.lock()
        defer { lock.unlock() }
        return sharedFrame
    }

    /// 설정대로 듣는다 (nil이면 멈춘다). 같은 설정이면 그대로
    func apply(_ newConfig: Config?) {
        queue.async { [self] in
            guard newConfig != config || (newConfig != nil && listener == nil) else { return }
            let portChanged = newConfig?.port != config?.port || newConfig?.name != config?.name
            let tokenChanged = newConfig?.token != config?.token
            config = newConfig
            guard let newConfig else {
                stopListening()
                updateStatus { $0 = FaceLinkStatus() }
                appLog("facelink: stopped")
                return
            }
            if tokenChanged || (!newConfig.acceptVMC && active != nil && active?.helloName == nil) {
                dropActive()
            }
            if portChanged || listener == nil {
                advertise = true
                startListening()
            }
        }
    }

    /// 보내는 쪽에 "정면 맞추기"를 보낸다
    func calibrate() {
        queue.async { [self] in
            guard let active else { return }
            send(OSC.encode("/FaceLink/Calibrate", []), to: active)
            appLog("facelink: asked \(active.helloName ?? active.address) to calibrate")
        }
    }

    // MARK: 듣기

    private func startListening() {
        stopListening()
        guard let config, let port = NWEndpoint.Port(rawValue: config.port) else { return }
        let parameters = NWParameters.udp
        parameters.allowLocalEndpointReuse = true
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters, on: port)
        } catch {
            fail("could not listen on port \(config.port): \(error.localizedDescription)")
            return
        }
        if advertise {
            listener.service = NWListener.Service(
                name: config.name, type: "_facelink._udp", txtRecord: NWTXTRecord(["v": "1", "name": config.name]))
            listener.serviceRegistrationUpdateHandler = { [weak self] change in
                guard let self else { return }
                switch change {
                case .add(let endpoint):
                    appLog("facelink: advertised \(endpoint)")
                    updateStatus { $0.advertised = config.name }
                case .remove:
                    updateStatus { $0.advertised = nil }
                @unknown default:
                    break
                }
            }
        }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self, let listener, listener === self.listener else { return }
            switch state {
            case .ready:
                appLog("facelink: listening on UDP \(config.port)\(advertise ? " (Bonjour _facelink._udp)" : "")")
                updateStatus {
                    $0.listening = true
                    $0.port = config.port
                    $0.error = nil
                    if $0.state == .off { $0.state = .waiting }
                }
            case .failed(let error):
                // LiveContainer 등에서 Bonjour 알림이 막히면 듣기까지 실패할 수 있다: 알림 없이 다시
                if case .dns(_) = error, advertise {
                    appLog("facelink: Bonjour unavailable (\(error)), listening without it")
                    advertise = false
                    startListening()
                } else {
                    fail("listener failed: \(error)")
                }
            case .waiting(let error):
                appLog("facelink: listener waiting: \(error)")
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        self.listener = listener
        listener.start(queue: queue)
        startTimer()
    }

    private func stopListening() {
        restart?.cancel()
        restart = nil
        listener?.cancel()
        listener = nil
        timer?.cancel()
        timer = nil
        for peer in peers.values { peer.connection.cancel() }
        peers.removeAll()
        active = nil
    }

    /// 포트가 쓰이는 중이면 등: 5초 뒤 다시
    private func fail(_ message: String) {
        appLog("facelink: \(message)")
        updateStatus {
            $0.listening = false
            $0.error = message
        }
        listener?.cancel()
        listener = nil
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.config != nil, self.listener == nil else { return }
            self.startListening()
        }
        restart = item
        queue.asyncAfter(deadline: .now() + 5, execute: item)
    }

    private func accept(_ connection: NWConnection) {
        // 주소를 바꿔 가며 보내는 패킷에 연결이 쌓이지 않게
        if peers.count >= 16, let oldest = peers.values.filter({ $0 !== active }).min(by: { $0.lastPacket < $1.lastPacket })
        {
            oldest.connection.cancel()
            peers[oldest.connection.endpoint] = nil
        }
        let peer = Peer(connection)
        peers[connection.endpoint] = peer
        connection.stateUpdateHandler = { [weak self, weak peer] state in
            guard let self, let peer else { return }
            switch state {
            case .failed(_), .cancelled:
                if self.peers[peer.connection.endpoint] === peer { self.peers[peer.connection.endpoint] = nil }
                if self.active === peer { self.active = nil }
            default:
                break
            }
        }
        connection.start(queue: queue)
        receive(peer)
    }

    private func receive(_ peer: Peer) {
        peer.connection.receiveMessage { [weak self, weak peer] data, _, _, error in
            guard let self, let peer else { return }
            if let data, !data.isEmpty { self.handle(packet: data, from: peer) }
            if error == nil, self.peers[peer.connection.endpoint] === peer { self.receive(peer) }
        }
    }

    // MARK: 패킷

    private func handle(packet: Data, from peer: Peer) {
        let now = ProcessInfo.processInfo.systemUptime
        peer.lastPacket = now
        guard packet.count <= 65_000, let messages = OSC.decode([UInt8](packet)) else {
            updateStatus { $0.invalid += 1 }
            return
        }
        var ignoredPacket = false
        for message in messages {
            if message.address == "/FaceLink/Hello" {
                hello(message, from: peer, now: now)
                continue
            }
            guard message.address.hasPrefix("/VMC/") || message.address.hasPrefix("/FaceLink/") else { continue }
            if peer !== active {
                // 토큰 없이 VMC만 보내는 앱은 설정으로 허락했을 때만, 지금 받는 쪽이 없거나 끊겼을 때
                if let config, config.acceptVMC, peer.helloName == nil, activeIsIdle(now) {
                    activate(peer, vmc: true)
                } else {
                    ignoredPacket = true
                    continue
                }
            }
            handleFrameMessage(message, from: peer, now: now)
        }
        if ignoredPacket { updateStatus { $0.ignored += 1 } }
    }

    private func activeIsIdle(_ now: TimeInterval) -> Bool {
        guard let active else { return true }
        return now - max(active.lastPacket, lastFrameTime) > 1
    }

    /// /FaceLink/Hello: s 버전, s 기기 이름, s 앱 버전, s 세션 ID, s 페어링 토큰
    private func hello(_ message: OSC.Message, from peer: Peer, now: TimeInterval) {
        guard let config, let version = message.string(0), let name = message.string(1) else { return }
        let token = message.string(4) ?? ""
        guard !config.token.isEmpty, token == config.token else {
            if !peer.warnedToken {
                peer.warnedToken = true
                appLog("facelink: ignored hello from \(peer.address) (pairing code mismatch)")
            }
            updateStatus { $0.ignored += 1 }
            return
        }
        let session = message.string(3) ?? ""
        if peer.session != session {
            peer.session = session
            peer.lastSequence = nil
            peer.pending = nil
        }
        // 이름은 화면과 로그에만 쓴다. 너무 길면 자른다
        peer.helloName = String(name.prefix(64))
        peer.helloApp = message.string(2).map { String($0.prefix(32)) }
        if peer !== active && activeIsIdle(now) {
            appLog("facelink: sender '\(peer.helloName ?? "")' \(peer.address) (protocol \(version), app \(peer.helloApp ?? "?"))")
            activate(peer, vmc: false)
        } else if peer === active {
            updateStatus {
                $0.senderName = peer.helloName
                $0.senderApp = peer.helloApp
                $0.senderIsVMC = false
            }
        }
    }

    private func activate(_ peer: Peer, vmc: Bool) {
        active = peer
        if vmc { appLog("facelink: VMC sender \(peer.address) (no FaceLink hello)") }
        lostLogged = false
        disconnectedLogged = false
        updateStatus {
            $0.senderName = vmc ? "VMC 앱" : peer.helloName
            $0.senderAddress = peer.address
            $0.senderApp = peer.helloApp
            $0.senderIsVMC = vmc
            $0.state = .waiting
        }
    }

    private func dropActive() {
        active = nil
        updateStatus {
            $0.senderName = nil
            $0.senderAddress = nil
            $0.senderApp = nil
            if $0.listening { $0.state = .waiting }
        }
    }

    private func handleFrameMessage(_ message: OSC.Message, from peer: Peer, now: TimeInterval) {
        switch message.address {
        case "/FaceLink/Frame":
            // i 순번, f 보낸 시각, i 추적 상태
            guard let sequence = message.int(0) else { return }
            var frame = lastFrame
            frame.sequence = sequence
            frame.sentTime = message.float(1) ?? 0
            frame.tracking = (message.int(2) ?? 1) != 0
            peer.pendingStale = peer.lastSequence.map { !Self.isNewer(sequence, than: $0) } ?? false
            if peer.pendingStale { updateStatus { $0.stale += 1 } }
            peer.pending = frame
        case "/VMC/Ext/Bone/Pos":
            guard let name = message.string(0) else { return }
            let numbers = (1...7).compactMap { message.float($0) }
            guard numbers.count == 7 else { return }
            var rotation = simd_quatf(ix: numbers[3], iy: numbers[4], iz: numbers[5], r: numbers[6])
            guard simd_length(rotation.vector) > 0.001 else { return }
            rotation = simd_normalize(rotation)
            var frame = pendingFrame(peer)
            switch name {
            case "Head":
                // 이상한 값이 아바타를 날려 보내지 않게 위치는 1m 안으로
                frame.headPosition = simd_clamp(
                    SIMD3<Float>(numbers[0], numbers[1], numbers[2]), SIMD3<Float>(repeating: -1),
                    SIMD3<Float>(repeating: 1))
                frame.headRotation = rotation
            case "LeftEye": frame.leftEye = rotation
            case "RightEye": frame.rightEye = rotation
            default: return
            }
            peer.pending = frame
        case "/VMC/Ext/Blend/Val":
            guard let name = message.string(0), let value = message.float(1), let index = FaceBlendShape.index(name)
            else { return }
            var frame = pendingFrame(peer)
            frame.blendShapes[index] = min(max(value, 0), 1)
            frame.present |= 1 << UInt64(index)
            peer.pending = frame
        case "/VMC/Ext/Blend/Apply":
            guard let frame = peer.pending else { return }
            peer.pending = nil
            guard !peer.pendingStale else { return }
            commit(frame, from: peer, now: now)
        default:
            break
        }
    }

    /// FaceLink Frame 없이 오는 VMC: 이전 값에서 이어 받고 순번은 여기서 붙인다
    private func pendingFrame(_ peer: Peer) -> FaceFrame {
        if let pending = peer.pending { return pending }
        var frame = lastFrame
        frame.sequence = lastFrame.sequence &+ 1
        frame.tracking = true
        peer.pendingStale = false
        return frame
    }

    /// 같은 세션의 순번은 1씩 늘고 2^31-1 다음은 0
    private static func isNewer(_ sequence: Int32, than last: Int32) -> Bool {
        sequence > last || Int64(last) - Int64(sequence) > 1_000_000_000
    }

    private func commit(_ frame: FaceFrame, from peer: Peer, now: TimeInterval) {
        var frame = frame
        frame.receivedAt = now
        peer.lastSequence = frame.sequence
        lastFrame = frame
        lastFrameTime = now
        frameTimes.append(now)
        lock.lock()
        sharedFrame = frame
        sharedStatus.frames += 1
        sharedStatus.lastSequence = frame.sequence
        if !frame.tracking { sharedStatus.trackingLostFrames += 1 }
        let newState: FaceLinkStatus.State = frame.tracking ? .receiving : .faceLost
        let changed = sharedStatus.state != newState
        sharedStatus.state = newState
        lock.unlock()
        if changed {
            if newState == .faceLost && !lostLogged {
                lostLogged = true
                appLog("facelink: the sender lost the face")
            } else if newState == .receiving {
                if lostLogged || disconnectedLogged { appLog("facelink: receiving again") }
                lostLogged = false
                disconnectedLogged = false
            }
        }
    }

    // MARK: 1초마다

    private func startTimer() {
        timer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        frameTimes.removeAll { now - $0 > 1 }
        let fps = Double(frameTimes.count)
        updateStatus { $0.fps = fps }

        // 1초 넘게 프레임이 없으면 끊김 (아바타는 중립으로)
        if active != nil, lastFrameTime > 0, now - lastFrameTime > 1 {
            let wasConnected = status().state == .receiving || status().state == .faceLost
            if wasConnected {
                updateStatus {
                    $0.state = .disconnected
                    $0.disconnects += 1
                }
                if !disconnectedLogged {
                    disconnectedLogged = true
                    appLog("facelink: no frames for 1 s (disconnected)")
                }
            }
        }

        // 받는 중인 쪽에 Ack: i 마지막 순번, f 초당 프레임, s 이름
        if let active, now - active.lastPacket < 3, let config {
            let ack = OSC.encode(
                "/FaceLink/Ack", [.int(active.lastSequence ?? 0), .float(Float(fps)), .string(config.name)])
            send(ack, to: active)
        }

        // 오래 조용한 연결은 닫는다
        for peer in peers.values where peer !== active && now - peer.lastPacket > 30 {
            peer.connection.cancel()
            peers[peer.connection.endpoint] = nil
        }

        if now >= nextLog, fps > 0 {
            nextLog = now + 10
            appLog(String(format: "facelink: %.0f fps from %@", fps, active?.helloName ?? active?.address ?? "?"))
        }
    }

    private func send(_ data: Data, to peer: Peer) {
        peer.connection.send(content: data, completion: .idempotent)
    }

    private func updateStatus(_ change: (inout FaceLinkStatus) -> Void) {
        lock.lock()
        change(&sharedStatus)
        lock.unlock()
    }
}

// MARK: - 앱 쪽

@MainActor
final class FaceLinkReceiver: ObservableObject {
    static let shared = FaceLinkReceiver()

    @Published private(set) var status = FaceLinkStatus()
    @Published private(set) var preview: FaceFrame?
    /// 페어링 코드 (QR에 들어간다)
    @Published private(set) var token = UserDefaults.standard.string(forKey: AppSettings.faceLinkToken) ?? ""

    private let engine = FaceLinkEngine()
    private var timer: Timer?
    /// 설정 화면이 받은 값을 보고 있을 때
    var previewing = false

    /// 아바타 소스가 읽는다 (어느 스레드에서나)
    nonisolated func latestFrame() -> FaceFrame? { engine.latestFrame() }

    /// 설정을 읽어 듣기를 켜거나 끈다
    func applySettings() {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: AppSettings.faceLinkEnabled) else {
            engine.apply(nil)
            timer?.invalidate()
            timer = nil
            status = FaceLinkStatus()
            preview = nil
            return
        }
        if token.isEmpty { regenerateToken() }
        let port = defaults.integer(forKey: AppSettings.faceLinkPort)
        engine.apply(
            FaceLinkEngine.Config(
                port: UInt16(clamping: (1024...65535).contains(port) ? port : 39539), token: token,
                acceptVMC: defaults.bool(forKey: AppSettings.faceLinkAcceptVMC), name: UIDevice.current.name))
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
    }

    /// 페어링 코드 (QR에 들어간다). 바꾸면 지금 보내는 쪽은 다시 연결해야 한다
    func regenerateToken() {
        let letters = Array("abcdefghjkmnpqrstuvwxyz23456789")
        token = String((0..<8).map { _ in letters.randomElement()! })
        UserDefaults.standard.set(token, forKey: AppSettings.faceLinkToken)
        appLog("facelink: new pairing code")
        if timer != nil { applySettings() }
    }

    func calibrate() { engine.calibrate() }

    private func refresh() {
        let latest = engine.status()
        if latest != status { status = latest }
        if previewing { preview = engine.latestFrame() }
    }

    /// QR에 넣는 주소: facelink://IP:포트?v=1&name=이름&token=코드 (IP마다 하나)
    func pairings() -> [FaceLinkPairing] {
        let port =
            status.port == 0 ? UInt16(clamping: UserDefaults.standard.integer(forKey: AppSettings.faceLinkPort)) : status.port
        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "v", value: "1"), URLQueryItem(name: "name", value: UIDevice.current.name),
            URLQueryItem(name: "token", value: token),
        ]
        let query = components.percentEncodedQuery ?? ""
        return Self.localAddresses().map { ip in
            FaceLinkPairing(address: "\(ip):\(port)", url: "facelink://\(ip):\(port)?\(query)")
        }
    }

    /// Wi-Fi·유선 등의 IPv4 주소 (셀룰러·VPN·루프백 빼고)
    static func localAddresses() -> [String] {
        var result: [String] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = pointer.pointee
            guard let address = interface.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                interface.ifa_flags & UInt32(IFF_UP) != 0, interface.ifa_flags & UInt32(IFF_LOOPBACK) == 0
            else { continue }
            let name = String(cString: interface.ifa_name)
            guard name.hasPrefix("en") || name.hasPrefix("bridge") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
                == 0
            {
                result.append(String(cString: host))
            }
        }
        return result
    }

    // MARK: CI

    /// CI (`-autotest-facelink <페어링 코드>`): ios/scripts/facelink-sender.py가 보내는 합성 값을 받는다.
    /// 받기, 정면 맞추기 명령, 얼굴 놓침, 끊김, 토큰 없는 VMC·잘못된 패킷·지난 순번을 버리는지 본다
    func runAutotest() async {
        appLog("facelink autotest: start")
        func wait(_ seconds: Double, until condition: () -> Bool) async -> Bool {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline {
                if condition() { return true }
                try? await Task.sleep(for: .milliseconds(250))
            }
            return condition()
        }

        let receiving = await wait(90) { status.state == .receiving && status.frames >= 120 }
        let frame = latestFrame()
        let headTurned = frame.map { abs($0.headRotation.angle) > 0.01 } ?? false
        let eyes = frame?.leftEye != nil && frame?.rightEye != nil
        appLog(
            "facelink autotest: receiving \(receiving ? "ok" : "failed") (sender '\(status.senderName ?? "-")', "
                + String(format: "%.0f fps, ", status.fps)
                + "blendshapes \(frame?.presentCount ?? 0)/\(FaceBlendShape.names.count), head \(headTurned ? "yes" : "no"), "
                + "eyes \(eyes ? "yes" : "no"))")
        calibrate()

        let lost = await wait(30) { status.trackingLostFrames > 0 }
        appLog("facelink autotest: face lost \(lost ? "seen" : "not seen")")
        let disconnected = await wait(40) { status.disconnects > 0 && status.state == .disconnected }
        appLog("facelink autotest: disconnect \(disconnected ? "seen" : "not seen")")

        let filtered = status.ignored > 0 && status.invalid > 0 && status.stale > 0
        appLog(
            "facelink autotest: filtered (ignored \(status.ignored), invalid \(status.invalid), stale \(status.stale))")
        let ok =
            receiving && frame?.presentCount == FaceBlendShape.names.count && headTurned && eyes && lost && disconnected
            && filtered && status.senderName == "CI 송신기"
        appLog("facelink autotest: \(ok ? "ok" : "failed")")
    }
}

// MARK: - 설정 화면

struct FaceLinkPairing: Hashable {
    let address: String
    let url: String
}

/// 설정 › 얼굴 추적: 받기 켜기, QR·주소·페어링 코드, 상태, 받은 값
struct FaceLinkSettingsView: View {
    @ObservedObject private var receiver = FaceLinkReceiver.shared
    @AppStorage(AppSettings.faceLinkEnabled) private var enabled = false
    @AppStorage(AppSettings.faceLinkPort) private var port = 39539
    @AppStorage(AppSettings.faceLinkAcceptVMC) private var acceptVMC = false
    @State private var portText = ""
    /// 주소와 QR은 포트·코드가 바뀔 때만 다시 만든다 (상태는 초당 5번 바뀐다)
    @State private var pairings: [FaceLinkPairing] = []
    @State private var qr: UIImage?

    var body: some View {
        Form {
            Section {
                Toggle("아이폰에서 받기", isOn: $enabled)
            } footer: {
                Text("아이폰 컴패니언 앱이 보내는 얼굴 추적 값(표정, 머리 방향)을 같은 Wi-Fi에서 받습니다. 영상은 오가지 않습니다. 처음 켜면 iPad가 로컬 네트워크 사용을 물을 수 있습니다.")
            }

            if enabled {
                connectionSection
                statusSection
                valuesSection
            }
        }
        .navigationTitle("얼굴 추적")
        .onAppear {
            portText = String(port)
            receiver.previewing = true
        }
        .onDisappear { receiver.previewing = false }
        .onChange(of: enabled) { _, _ in receiver.applySettings() }
        .onChange(of: acceptVMC) { _, _ in receiver.applySettings() }
        .task(id: "\(enabled) \(receiver.status.port) \(receiver.token)") {
            pairings = receiver.pairings()
            qr = pairings.first.flatMap { Self.qrImage($0.url) }
        }
    }

    private var connectionSection: some View {
        Section {
            if let image = qr {
                HStack {
                    Spacer()
                    Image(uiImage: image)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 180, height: 180)
                        .accessibilityLabel("연결 QR 코드")
                    Spacer()
                }
            }
            if pairings.isEmpty {
                Text("Wi-Fi 주소를 찾지 못했습니다. Wi-Fi에 연결하세요.").foregroundStyle(.secondary)
            }
            ForEach(pairings, id: \.address) { pairing in
                LabeledContent("주소", value: pairing.address)
            }
            LabeledContent("페어링 코드", value: receiver.token)
            Button("페어링 코드 다시 만들기") { receiver.regenerateToken() }
            HStack {
                Text("포트")
                TextField("39539", text: $portText)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .onSubmit(applyPort)
                Button("적용", action: applyPort)
                    .disabled(Int(portText) == port)
            }
            Toggle("다른 VMC 앱 받기 (Waidayo 등)", isOn: $acceptVMC)
        } header: {
            Text("연결")
        } footer: {
            Text("아이폰 앱에서 QR을 찍거나 주소와 페어링 코드를 넣으세요. 페어링 코드가 맞는 아이폰 하나만 받습니다. \"다른 VMC 앱 받기\"를 켜면 코드 없이 VMC로 보내는 앱도 받습니다.")
        }
    }

    private var statusSection: some View {
        let status = receiver.status
        return Section("상태") {
            LabeledContent("받기", value: stateText(status))
            if let name = status.senderName {
                LabeledContent("보내는 쪽", value: [name, status.senderApp.map { "앱 \($0)" }].compactMap { $0 }.joined(separator: " · "))
                if let address = status.senderAddress { LabeledContent("보내는 주소", value: address) }
            }
            LabeledContent("Bonjour", value: status.advertised.map { "\"\($0)\"로 알리는 중" } ?? "알리지 못함 (QR·주소로 연결)")
            if let error = status.error {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
            Button("정면 맞추기 (아이폰에 보내기)") { receiver.calibrate() }
                .disabled(status.senderName == nil || status.senderIsVMC)
        }
    }

    private var valuesSection: some View {
        Section("받은 값") {
            if let frame = receiver.preview {
                ForEach(["EyeBlinkLeft", "EyeBlinkRight", "JawOpen", "MouthSmileLeft", "MouthSmileRight", "BrowInnerUp"], id: \.self) {
                    name in
                    LabeledContent(name) {
                        ProgressView(value: Double(frame.value(name)))
                            .frame(width: 140)
                    }
                }
                let angles = Self.headAngles(frame.headRotation)
                LabeledContent(
                    "머리 (좌우·위아래·기울기)",
                    value: String(format: "%.0f° · %.0f° · %.0f°", angles.x, angles.y, angles.z))
                LabeledContent("받은 블렌드셰이프", value: "\(frame.presentCount)/\(FaceBlendShape.names.count)")
            } else {
                Text("아직 받은 값이 없습니다").foregroundStyle(.secondary)
            }
        }
    }

    private func stateText(_ status: FaceLinkStatus) -> String {
        if !status.listening { return status.error == nil ? "준비 중…" : "듣지 못함" }
        switch status.state {
        case .off: return "꺼짐"
        case .waiting: return "UDP \(status.port)에서 기다리는 중"
        case .receiving: return String(format: "받는 중 · %.0f fps", status.fps)
        case .faceLost: return "아이폰이 얼굴을 놓침"
        case .disconnected: return "끊김 (1초 넘게 안 옴)"
        }
    }

    private func applyPort() {
        guard let value = Int(portText), (1024...65535).contains(value) else {
            portText = String(port)
            return
        }
        port = value
        receiver.applySettings()
    }

    /// 좌우(yaw)·위아래(pitch)·기울기(roll), 도. VMC(Unity) 좌표의 앞(+Z)·위(+Y) 방향으로 계산 (보기용)
    static func headAngles(_ rotation: simd_quatf) -> SIMD3<Float> {
        let forward = rotation.act(SIMD3<Float>(0, 0, 1))
        let up = rotation.act(SIMD3<Float>(0, 1, 0))
        let yaw = atan2(forward.x, forward.z)
        let pitch = asin(max(-1, min(1, -forward.y)))
        let roll = atan2(-up.x, up.y)
        return SIMD3(yaw, pitch, roll) * (180 / .pi)
    }

    static func qrImage(_ text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
            let image = CIContext().createCGImage(output, from: output.extent)
        else { return nil }
        return UIImage(cgImage: image)
    }
}
