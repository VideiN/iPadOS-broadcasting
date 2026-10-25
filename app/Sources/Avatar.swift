import CoreVideo
import Foundation
import ImageIO
import IOSurface
import Metal
import QuartzCore
import RealityKit
import UIKit
import UniformTypeIdentifiers
import VRMRealityKit
import simd

/// 아바타 소스 (P9): VRM 모델을 VRMKit(MIT)으로 불러와 RealityKit(RealityRenderer, iOS 18+)으로 IOSurface에 그리고,
/// Core/avatar-source.c가 그것을 OBS 소스로 보인다. 아이폰 얼굴 추적(FaceLink.swift)을 받고 있으면 표정·고개·시선을 따른다.

// MARK: - C 소스와 잇기

enum AvatarSources {
    /// core_startup 전에 부른다. iOS 18 미만이면 소스를 등록하지 않는다
    static func install() {
        guard #available(iOS 18.0, *) else {
            appLog("avatar: needs iOS 18 (RealityRenderer)")
            return
        }
        var callbacks = core_avatar_callbacks(
            create: { context, json in
                guard let context else { return nil }
                let host = AvatarSourceHost(context: context)
                let settings = json.map { String(cString: $0) } ?? "{}"
                DispatchQueue.main.async { MainActor.assumeIsolated { host.start(settings) } }
                return Unmanaged.passRetained(host).toOpaque()
            },
            update: { raw, json in
                guard let raw else { return }
                let host = Unmanaged<AvatarSourceHost>.fromOpaque(raw).takeUnretainedValue()
                let settings = json.map { String(cString: $0) } ?? "{}"
                DispatchQueue.main.async { MainActor.assumeIsolated { host.apply(settings) } }
            },
            destroy: { raw in
                guard let raw else { return }
                let host = Unmanaged<AvatarSourceHost>.fromOpaque(raw).takeRetainedValue()
                host.detach()
                DispatchQueue.main.async { MainActor.assumeIsolated { host.stop() } }
            },
            set_showing: { raw, showing in
                guard let raw else { return }
                let host = Unmanaged<AvatarSourceHost>.fromOpaque(raw).takeUnretainedValue()
                DispatchQueue.main.async { MainActor.assumeIsolated { host.setShowing(showing) } }
            },
            copy_status: { raw, buffer, size in
                guard let raw, let buffer, size > 0 else { return }
                let host = Unmanaged<AvatarSourceHost>.fromOpaque(raw).takeUnretainedValue()
                _ = host.status.withCString { strlcpy(buffer, $0, size) }
            })
        core_avatar_set_callbacks(&callbacks)
    }
}

/// 소스 하나의 앱 쪽. C가 어느 스레드에서나 부르므로 그리기는 메인 스레드의 AvatarRenderer가 하고,
/// 여기는 C 소스 주소(context)와 상태 글만 잠금으로 지킨다
@available(iOS 18.0, *)
final class AvatarSourceHost: @unchecked Sendable {
    private let lock = NSLock()
    private var context: UnsafeMutableRawPointer?
    private var statusText = "VRM 모델 파일을 고르세요."
    @MainActor private var renderer: AvatarRenderer?

    init(context: UnsafeMutableRawPointer) {
        self.context = context
    }

    var status: String {
        get { lock.withLock { statusText } }
        set { lock.withLock { statusText = newValue } }
    }

    /// 다 그린 표면을 소스에 넘긴다 (GPU 완료 스레드에서). 소스가 사라졌으면 버린다
    func present(_ surface: IOSurface) {
        lock.withLock {
            if let context { core_avatar_present(context, surface) }
        }
    }

    /// C 소스가 사라진다: 이 뒤로는 present가 아무것도 하지 않는다
    func detach() {
        lock.withLock { context = nil }
    }

    @MainActor func start(_ json: String) {
        renderer = AvatarRenderer(host: self)
        renderer?.apply(AvatarSettings(json: json))
    }

    @MainActor func apply(_ json: String) {
        renderer?.apply(AvatarSettings(json: json))
    }

    @MainActor func setShowing(_ showing: Bool) {
        renderer?.setShowing(showing)
    }

    @MainActor func stop() {
        renderer?.stop()
        renderer = nil
    }
}

struct AvatarSettings: Equatable {
    var model = ""
    var framing = "bust"
    var faceTracking = true
    var mirror = true
    var width = 1080
    var height = 1080
    var fps = 30

    init() {}

    init(json: String) {
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else { return }
        model = object["model"] as? String ?? ""
        framing = object["framing"] as? String ?? framing
        faceTracking = object["face_tracking"] as? Bool ?? faceTracking
        mirror = object["mirror"] as? Bool ?? mirror
        width = min(max((object["width"] as? NSNumber)?.intValue ?? width, 16), 4096)
        height = min(max((object["height"] as? NSNumber)?.intValue ?? height, 16), 4096)
        fps = min(max((object["fps"] as? NSNumber)?.intValue ?? fps, 1), 60)
    }
}

// MARK: - 그리기

@available(iOS 18.0, *)
@MainActor
final class AvatarRenderer {
    /// 그릴 곳 하나. 소스가 보이는 동안(use count)과 GPU가 그리는 동안(inFlight)은 다시 쓰지 않는다
    private final class Target: @unchecked Sendable {
        let surface: IOSurface
        let texture: MTLTexture
        private let lock = NSLock()
        private var drawing = false
        var lastUsed = 0

        init(surface: IOSurface, texture: MTLTexture) {
            self.surface = surface
            self.texture = texture
        }

        var inFlight: Bool {
            get { lock.withLock { drawing } }
            set { lock.withLock { drawing = newValue } }
        }
    }

    /// 고개 돌림을 나눠 받는 뼈 (정지 자세)
    private struct BoneRest {
        let index: Int
        let parent: Int?
        /// 모델 공간의 정지 회전
        let restModel: simd_quatf
    }

    /// FaceLink 블렌드셰이프 → 이 모델의 표정
    private struct FaceMap {
        /// 퍼펙트 싱크 모델: ARKit 이름의 표정이 있으면 그대로 (블렌드셰이프 번호, 표정)
        var perfectSync: [(index: Int, handle: ExpressionHandle)] = []
        var blinkLeft: ExpressionHandle?
        var blinkRight: ExpressionHandle?
        var blink: ExpressionHandle?
        var aa: ExpressionHandle?
        var ee: ExpressionHandle?
        var ou: ExpressionHandle?
        var oh: ExpressionHandle?
        var happy: ExpressionHandle?
        var all: [ExpressionHandle] {
            perfectSync.map(\.handle) + [blinkLeft, blinkRight, blink, aa, ee, ou, oh, happy].compactMap { $0 }
        }
    }

    private weak var host: AvatarSourceHost?
    private var settings = AvatarSettings()
    private var showing = false
    private let device = MTLCreateSystemDefaultDevice()
    private var renderer: RealityRenderer?
    private let root = Entity()
    private let camera = PerspectiveCamera()
    private var model: VRMEntity?
    private var modelName = ""
    private var loading: Task<Void, Never>?
    private var targets: [Target] = []
    private var displayLink: CADisplayLink?
    private var lastTick: CFTimeInterval = 0
    private var frames = 0
    private var skipped = 0
    private var renderErrorLogged = false

    private var neck: BoneRest?
    private var head: BoneRest?
    /// VRM의 기본 자세는 팔을 옆으로 편 T 자세: 위팔을 아래로 내리는 회전 (모델 공간)
    private var arms: [(bone: BoneRest, turn: simd_quatf)] = []
    private var facesPlusZ = true
    private var faceMap = FaceMap()
    private var headDelta = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
    private var neutral = true
    /// 블렌드셰이프 번호 → 좌우를 바꾼 번호 (거울)
    private static let mirrored: [Int] = FaceBlendShape.names.map { name in
        let swapped = name.replacingOccurrences(of: "Left", with: "\u{1}")
            .replacingOccurrences(of: "Right", with: "Left")
            .replacingOccurrences(of: "\u{1}", with: "Right")
        return FaceBlendShape.index(swapped) ?? FaceBlendShape.index(name)!
    }

    init(host: AvatarSourceHost) {
        self.host = host
        do {
            let renderer = try RealityRenderer()
            renderer.cameraSettings.colorBackground = .color(CGColor(red: 0, green: 0, blue: 0, alpha: 0))
            camera.camera.fieldOfViewInDegrees = 20
            root.addChild(camera)
            let light = DirectionalLight()
            light.light.intensity = 2000
            light.look(at: [0, 1.2, 0], from: [0.6, 2.2, 2.5], relativeTo: nil)
            root.addChild(light)
            renderer.entities.append(root)
            renderer.activeCamera = camera
            self.renderer = renderer
        } catch {
            appLog("avatar: RealityRenderer failed: \(error)")
            host.status = "이 기기에서 3D를 그릴 수 없습니다: \(error.localizedDescription)"
        }
    }

    func apply(_ new: AvatarSettings) {
        let old = settings
        settings = new
        if new.width != old.width || new.height != old.height || targets.isEmpty {
            targets = makeTargets(width: new.width, height: new.height)
        }
        if new.model != old.model || (model == nil && loading == nil && !new.model.isEmpty) {
            if new.model != old.model {
                appLog("avatar: model setting '\(URL(fileURLWithPath: new.model).lastPathComponent)'")
            }
            load(new.model)
        } else if new.framing != old.framing || new.width != old.width || new.height != old.height {
            frameCamera()
        }
        if new.fps != old.fps { displayLink?.preferredFrameRateRange = Self.frameRange(new.fps) }
        updateLink()
    }

    func setShowing(_ showing: Bool) {
        self.showing = showing
        updateLink()
    }

    func stop() {
        loading?.cancel()
        displayLink?.invalidate()
        displayLink = nil
        model?.removeFromParent()
        model = nil
        targets = []
    }

    // MARK: 모델

    /// 기기를 바꾸거나 앱을 다시 설치하면 앱 컨테이너 경로가 바뀐다: 같은 이름을 Documents에서 찾는다
    private static func resolve(_ path: String) -> URL? {
        guard !path.isEmpty else { return nil }
        if FileManager.default.fileExists(atPath: path) { return URL(fileURLWithPath: path) }
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let name = URL(fileURLWithPath: path).lastPathComponent
        for candidate in [documents.appendingPathComponent("Media").appendingPathComponent(name),
                          documents.appendingPathComponent(name)]
        where FileManager.default.fileExists(atPath: candidate.path) {
            return candidate
        }
        return nil
    }

    private func load(_ path: String) {
        loading?.cancel()
        loading = nil
        model?.removeFromParent()
        model = nil
        guard !path.isEmpty else {
            host?.status = "VRM 모델 파일을 고르세요."
            return
        }
        let name = URL(fileURLWithPath: path).lastPathComponent
        guard let url = Self.resolve(path) else {
            host?.status = "모델 파일을 찾지 못했습니다: \(name)"
            appLog("avatar: model file not found: \(name)")
            return
        }
        host?.status = "불러오는 중… \(name)"
        appLog("avatar: loading \(name)")
        let started = CACurrentMediaTime()
        loading = Task { @MainActor in
            defer { if !Task.isCancelled { loading = nil } }
            do {
                let loader = try VRMEntityLoader(withURL: url, outputColorSpace: .sRGB)
                let entity = try await loader.loadEntity()
                guard !Task.isCancelled, settings.model == path else { return }
                install(entity, name: name, seconds: CACurrentMediaTime() - started)
            } catch {
                guard !Task.isCancelled else { return }
                appLog("avatar: could not load \(name): \(error)")
                host?.status = "불러오지 못했습니다 (\(name)): \(error.localizedDescription)"
            }
        }
    }

    private func install(_ entity: VRMEntity, name: String, seconds: Double) {
        entity.isAutomaticUpdateEnabled = false
        // VRM 0.x는 -Z, 1.0은 +Z를 본다: 카메라(+Z 쪽에서 -Z를 봄)를 보게 돌린다
        facesPlusZ = entity.frontDirection.z >= 0
        if !facesPlusZ { entity.transform.rotation = simd_quatf(angle: .pi, axis: [0, 1, 0]) }
        root.addChild(entity)
        entity.setMToonLightDirection(simd_normalize(SIMD3<Float>(0.25, 0.5, 1)))
        model = entity
        modelName = name

        neck = rest(of: .neck, in: entity)
        head = rest(of: .head, in: entity)
        arms = []
        for (upper, lower) in [(HumanoidBone.leftUpperArm, HumanoidBone.leftLowerArm), (.rightUpperArm, .rightLowerArm)] {
            guard let bone = rest(of: upper, in: entity), let pose = entity.pose,
                let lowerIndex = entity.humanoid.nodeIndex(for: lower)
            else { continue }
            // 팔이 +X로 뻗었으면 Z축으로 -65°, -X면 +65° 돌려 아래로
            let reach = pose.modelMatrix(ofNode: lowerIndex).columns.3.x - pose.modelMatrix(ofNode: bone.index).columns.3.x
            arms.append((bone, simd_quatf(angle: (reach > 0 ? -65 : 65) * .pi / 180, axis: [0, 0, 1])))
        }
        faceMap = Self.faceMap(for: entity)
        headDelta = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        neutral = true
        entity.setUpdateHandler({ [weak self] _ in self?.poseHead() }, at: .afterAnimation)
        frameCamera()

        let version: String
        switch entity.vrm {
        case .v0: version = "0.x"
        case .v1: version = "1.0"
        }
        let expressions = entity.availableExpressions.count
        let mode = faceMap.perfectSync.isEmpty ? "presets" : "perfect sync \(faceMap.perfectSync.count)"
        appLog(String(format: "avatar: loaded '%@' (VRM %@) in %.1f s, %ld expressions, face %@, head %@",
                      name, version, seconds, expressions, mode, head == nil ? "missing" : "ok"))
        host?.status = "\(entity.name.isEmpty ? name : entity.name) · VRM \(version) · 표정 \(expressions)개"
            + (faceMap.perfectSync.isEmpty ? "" : " (퍼펙트 싱크)")
        frames = 0
        AvatarAutotest.modelLoaded(path: settings.model)
        updateLink()
    }

    private func rest(of bone: HumanoidBone, in entity: VRMEntity) -> BoneRest? {
        guard let pose = entity.pose, let index = entity.humanoid.nodeIndex(for: bone) else { return nil }
        return BoneRest(index: index, parent: pose.parent(ofNode: index), restModel: pose.modelRotation(ofNode: index))
    }

    private static func faceMap(for entity: VRMEntity) -> FaceMap {
        var map = FaceMap()
        for info in entity.availableExpressions {
            guard case .custom(let name) = info.key, let index = FaceBlendShape.index(name),
                let handle = entity.expressionHandle(for: info.key)
            else { continue }
            map.perfectSync.append((index, handle))
        }
        // 몇 개만 맞으면 우연이다: 프리셋으로
        if map.perfectSync.count < 20 { map.perfectSync = [] }
        map.blinkLeft = entity.expressionHandle(for: .preset(.blinkLeft))
        map.blinkRight = entity.expressionHandle(for: .preset(.blinkRight))
        if map.blinkLeft == nil || map.blinkRight == nil { map.blink = entity.expressionHandle(for: .preset(.blink)) }
        map.aa = entity.expressionHandle(for: .preset(.aa))
        map.ee = entity.expressionHandle(for: .preset(.ee))
        map.ou = entity.expressionHandle(for: .preset(.ou))
        map.oh = entity.expressionHandle(for: .preset(.oh))
        map.happy = entity.expressionHandle(for: .preset(.happy))
        return map
    }

    /// 구도에 맞춰 카메라를 둔다. 모델은 +Z를 보고, 카메라는 +Z 쪽에서 -Z를 본다
    private func frameCamera() {
        guard let model, let pose = model.pose else { return }
        func position(_ bone: HumanoidBone) -> SIMD3<Float>? {
            guard let index = model.humanoid.nodeIndex(for: bone) else { return nil }
            let local = pose.modelMatrix(ofNode: index).columns.3
            return model.convert(position: SIMD3<Float>(local.x, local.y, local.z), to: nil)
        }
        let bounds = model.visualBounds(relativeTo: nil)
        let headPoint = position(.head) ?? SIMD3<Float>(0, bounds.max.y - 0.15, 0)
        let hips = position(.hips) ?? SIMD3<Float>(0, (bounds.min.y + bounds.max.y) / 2, 0)
        let center: SIMD3<Float>
        let height: Float
        switch settings.framing {
        case "face":
            center = SIMD3<Float>(headPoint.x, headPoint.y + 0.07, headPoint.z)
            height = 0.42
        case "full":
            center = SIMD3<Float>(headPoint.x, (bounds.min.y + bounds.max.y) / 2, 0)
            height = (bounds.max.y - bounds.min.y) * 1.08
        default:
            let top = headPoint.y + 0.24
            let bottom = hips.y + 0.08
            center = SIMD3<Float>(headPoint.x, (top + bottom) / 2, headPoint.z)
            height = max(0.3, top - bottom)
        }
        // 세로 시야각에 맞춘다. 가로가 더 좁으면 가로에 맞춘다
        let aspect = Float(settings.width) / Float(settings.height)
        let fit = height * max(1, 0.75 / aspect)
        let distance = (fit / 2) / tan(camera.camera.fieldOfViewInDegrees / 2 * .pi / 180)
        camera.position = SIMD3<Float>(center.x, center.y, center.z + distance)
        camera.orientation = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
    }

    // MARK: 얼굴

    /// 모델 공간에서 고개 돌림(headDelta)의 반을 목, 나머지를 머리에 (정지 자세 기준이라 쌓이지 않는다)
    private func poseHead() {
        guard let pose = model?.pose else { return }
        func turn(_ bone: BoneRest?, by delta: simd_quatf) {
            guard let bone else { return }
            let parent = bone.parent.map { pose.modelRotation(ofNode: $0) } ?? simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
            pose.setLocalRotation(simd_normalize(parent.inverse * (delta * bone.restModel)), ofNode: bone.index)
        }
        let identity = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        if neck != nil {
            turn(neck, by: simd_slerp(identity, headDelta, 0.5))
        }
        turn(head, by: headDelta)
        for arm in arms { turn(arm.bone, by: arm.turn) }
    }

    /// FaceLink의 값(Unity 왼손 좌표, 사용자 기준) → 표정, 고개(headDelta), 시선
    private func applyFace() {
        guard let model else { return }
        let identity = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        var face: FaceFrame?
        if settings.faceTracking, let frame = FaceLinkReceiver.shared.latestFrame(), frame.tracking,
            ProcessInfo.processInfo.systemUptime - frame.receivedAt < 1
        {
            face = frame
        } else if let test = AvatarAutotest.testFace() {
            face = test
        }

        guard let face else {
            // 받지 않으면 정면, 무표정으로 천천히
            headDelta = simd_slerp(headDelta, identity, 0.15)
            if !neutral {
                var weights = model.makeExpressionWeights()
                for handle in faceMap.all { weights[handle] = 0 }
                model.setExpressions(weights)
                model.lookAtTarget = nil
                neutral = true
            }
            return
        }
        neutral = false
        let mirror = settings.mirror
        let shapes = face.blendShapes
        let mirrored = Self.mirrored
        func shape(_ index: Int) -> Float { shapes[mirror ? mirrored[index] : index] }
        func value(_ name: String) -> Float { FaceBlendShape.index(name).map { shape($0) } ?? 0 }

        // 고개: 거울이면 좌우(x)를 뒤집고, Unity(+Z 앞, +X 오른쪽, 왼손) → 모델 공간(오른손)으로
        var q = face.headRotation
        // 실기기(아이폰 FaceLink): 위아래(x축 회전)가 반대로 움직였다. 받은 값의 x축 성분을 뒤집는다 (좌우·기울기는 맞음)
        q = simd_quatf(ix: -q.imag.x, iy: q.imag.y, iz: q.imag.z, r: q.real)
        if mirror { q = simd_quatf(ix: q.imag.x, iy: -q.imag.y, iz: -q.imag.z, r: q.real) }
        q = facesPlusZ
            ? simd_quatf(ix: q.imag.x, iy: -q.imag.y, iz: -q.imag.z, r: q.real)
            : simd_quatf(ix: -q.imag.x, iy: -q.imag.y, iz: q.imag.z, r: q.real)
        if q.real < 0 { q = simd_quatf(vector: -q.vector) }
        // 너무 많이 돌지 않게 (70°)
        if q.angle > 70 * .pi / 180 { q = simd_quatf(angle: 70 * .pi / 180, axis: q.axis) }
        headDelta = simd_slerp(headDelta, q, 0.6)

        var weights = model.makeExpressionWeights()
        if !faceMap.perfectSync.isEmpty {
            for entry in faceMap.perfectSync { weights[entry.handle] = shape(entry.index) }
        } else {
            let left = value("EyeBlinkLeft")
            let right = value("EyeBlinkRight")
            if let handle = faceMap.blinkLeft { weights[handle] = left }
            if let handle = faceMap.blinkRight { weights[handle] = right }
            if let handle = faceMap.blink { weights[handle] = (left + right) / 2 }
            let jaw = value("JawOpen")
            let pucker = value("MouthPucker")
            let funnel = value("MouthFunnel")
            let stretch = (value("MouthStretchLeft") + value("MouthStretchRight")) / 2
            let smile = (value("MouthSmileLeft") + value("MouthSmileRight")) / 2
            func clamp(_ x: Float) -> Float { min(max(x, 0), 1) }
            if let handle = faceMap.aa { weights[handle] = clamp(jaw * 1.4 - pucker * 0.5) }
            if let handle = faceMap.ou { weights[handle] = clamp(pucker * 1.2) }
            if let handle = faceMap.oh { weights[handle] = clamp(funnel * 1.2) }
            if let handle = faceMap.ee { weights[handle] = clamp(stretch * 0.8) }
            if let handle = faceMap.happy { weights[handle] = clamp(smile * 1.1 - 0.1) * 0.8 }
        }
        model.setExpressions(weights)

        // 시선 (yaw는 모델의 왼쪽이 +, pitch는 위가 +)
        let yaw = (value("EyeLookOutLeft") + value("EyeLookInRight") - value("EyeLookInLeft") - value("EyeLookOutRight")) / 2
        let pitch = (value("EyeLookUpLeft") + value("EyeLookUpRight") - value("EyeLookDownLeft") - value("EyeLookDownRight")) / 2
        model.lookAtTarget = .angles(yaw: yaw * 25, pitch: pitch * 20)
    }

    // MARK: 매 프레임

    private static func frameRange(_ fps: Int) -> CAFrameRateRange {
        CAFrameRateRange(minimum: Float(fps), maximum: Float(fps), preferred: Float(fps))
    }

    private final class LinkProxy: NSObject {
        weak var owner: AvatarRenderer?
        @objc func tick(_ link: CADisplayLink) {
            MainActor.assumeIsolated { owner?.tick(link) }
        }
    }

    private func updateLink() {
        let run = showing && model != nil && renderer != nil && !targets.isEmpty
        if run, displayLink == nil {
            let proxy = LinkProxy()
            proxy.owner = self
            let link = CADisplayLink(target: proxy, selector: #selector(LinkProxy.tick(_:)))
            link.preferredFrameRateRange = Self.frameRange(settings.fps)
            link.add(to: .main, forMode: .common)
            displayLink = link
            lastTick = 0
        } else if !run, let link = displayLink {
            link.invalidate()
            displayLink = nil
        }
    }

    private func makeTargets(width: Int, height: Int) -> [Target] {
        guard let device else { return [] }
        let bytesPerRow = (width * 4 + 63) / 64 * 64
        let properties: [IOSurfacePropertyKey: Any] = [
            .width: width, .height: height, .bytesPerElement: 4, .bytesPerRow: bytesPerRow,
            .pixelFormat: kCVPixelFormatType_32BGRA,
        ]
        return (0..<3).compactMap { _ in
            guard let surface = IOSurface(properties: properties) else { return nil }
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm_srgb, width: width, height: height, mipmapped: false)
            descriptor.usage = [.renderTarget, .shaderRead]
            descriptor.storageMode = .shared
            guard let texture = device.makeTexture(descriptor: descriptor, iosurface: surface, plane: 0) else { return nil }
            return Target(surface: surface, texture: texture)
        }
    }

    /// 소스가 보이고 있지 않고 GPU가 그리고 있지 않은 표면. 모두 쓰이는 중이면 가장 오래된 것 (멈추지 않게)
    private func nextTarget() -> Target? {
        let free = targets.filter { !$0.inFlight }
        return free.filter { !$0.surface.isInUse }.min { $0.lastUsed < $1.lastUsed }
            ?? free.min { $0.lastUsed < $1.lastUsed }
    }

    private func tick(_ link: CADisplayLink) {
        guard let model, let renderer, UIApplication.shared.applicationState != .background else { return }
        let deltaTime = lastTick > 0 ? min(0.1, link.timestamp - lastTick) : 1.0 / Double(settings.fps)
        lastTick = link.timestamp

        applyFace()
        model.update(deltaTime: deltaTime)

        guard let target = nextTarget() else {
            skipped += 1
            return
        }
        frames += 1
        target.lastUsed = frames
        target.inFlight = true
        let host = host
        let frame = frames
        let name = modelName
        do {
            let output = try RealityRenderer.CameraOutput(.singleProjection(colorTexture: target.texture))
            try renderer.updateAndRender(
                deltaTime: deltaTime, cameraOutput: output,
                onComplete: { _ in
                    host?.present(target.surface)
                    target.inFlight = false
                    if frame == 1 { appLog("avatar: first frame of '\(name)'") }
                    AvatarAutotest.rendered(frame: frame, surface: target.surface)
                })
        } catch {
            target.inFlight = false
            if !renderErrorLogged {
                renderErrorLogged = true
                appLog("avatar: render failed: \(error)")
                host?.status = "그리지 못했습니다: \(error.localizedDescription)"
            }
        }
    }
}

// MARK: - CI

/// CI (`-autotest-avatar <VRM 1.0 파일>,<VRM 0.x 파일>`, Documents 안): 씬 시험이 첫 모델로 아바타 소스를 넣고,
/// 그림이 나오면 두 번 찍어(움직였는지) 다음 모델로 바꾼다. 얼굴 추적 값이 없으면 시험용 얼굴로 움직인다.
/// 찍은 그림은 Documents/avatar-<번호>-<a|b>.png
enum AvatarAutotest {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var models: [String] = {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "-autotest-avatar"), index + 1 < args.count else { return [] }
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return args[index + 1].split(separator: ",").map { documents.appendingPathComponent(String($0)).path }
    }()
    nonisolated(unsafe) private static var sourceName: String?
    nonisolated(unsafe) private static var stage = 0
    nonisolated(unsafe) private static var loadedAt: Int?
    nonisolated(unsafe) private static var firstSnapshot: [UInt8]?
    nonisolated(unsafe) private static var results: [String] = []
    nonisolated(unsafe) private static var allOK = true

    static var firstModel: String? { models.first.flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil } }

    /// 씬 시험이 소스를 넣은 뒤
    static func begin(sourceName name: String) {
        lock.withLock { sourceName = name }
        appLog("avatar autotest: start (\(models.count) models)")
    }

    /// 모델을 다 불러왔을 때 (메인 스레드)
    static func modelLoaded(path: String) {
        lock.withLock {
            guard stage < models.count, models[stage] == path else { return }
            loadedAt = -1
            firstSnapshot = nil
        }
    }

    /// 얼굴 추적 값이 없을 때 시험이 쓰는 얼굴: 고개를 좌우로, 입을 벌렸다 닫는다
    static func testFace() -> FaceFrame? {
        guard lock.withLock({ stage < models.count && sourceName != nil }) else { return nil }
        let t = Float(ProcessInfo.processInfo.systemUptime)
        var frame = FaceFrame()
        frame.headRotation = simd_quatf(angle: 0.35 * sin(t * 3), axis: [0, 1, 0])
        frame.blendShapes[FaceBlendShape.index("JawOpen")!] = 0.5 + 0.5 * sin(t * 4)
        frame.blendShapes[FaceBlendShape.index("EyeBlinkLeft")!] = sin(t * 5) > 0.6 ? 1 : 0
        frame.receivedAt = ProcessInfo.processInfo.systemUptime
        return frame
    }

    /// 그림 하나를 다 그렸을 때 (GPU 완료 스레드). 첫 그림부터 30장, 45장째를 찍는다
    static func rendered(frame: Int, surface: IOSurface) {
        lock.lock()
        guard stage < models.count, let start = loadedAt else {
            lock.unlock()
            return
        }
        if start < 0 { loadedAt = frame }
        let index = frame - (loadedAt ?? frame)
        let currentStage = stage
        lock.unlock()
        guard index == 30 || index == 45 else { return }

        let pixels = snapshot(surface, name: "avatar-\(currentStage + 1)-\(index == 30 ? "a" : "b")")
        let total = pixels.count / 4
        var covered = 0
        for i in 0..<total where pixels[i * 4 + 3] > 8 { covered += 1 }
        let coverage = Double(covered) / Double(max(total, 1)) * 100

        lock.lock()
        if index == 30 {
            firstSnapshot = pixels
            lock.unlock()
            appLog(String(format: "avatar autotest: model %ld drawn, alpha coverage %.1f%%", currentStage + 1, coverage))
            return
        }
        var changed = 0
        if let first = firstSnapshot, first.count == pixels.count {
            for i in stride(from: 0, to: pixels.count, by: 4)
            where abs(Int(first[i]) - Int(pixels[i])) + abs(Int(first[i + 1]) - Int(pixels[i + 1]))
                + abs(Int(first[i + 2]) - Int(pixels[i + 2])) + abs(Int(first[i + 3]) - Int(pixels[i + 3])) > 24 {
                changed += 1
            }
        }
        let moved = Double(changed) / Double(max(total, 1)) * 100
        // 모델이 그려졌고(덮인 곳), 바탕은 투명하고(덮이지 않은 곳), 두 장 사이에 움직였다
        let ok = coverage > 1 && coverage < 90 && moved > 0.05
        allOK = allOK && ok
        results.append(String(format: "model %ld %@ (coverage %.1f%%, moved %.2f%%)", currentStage + 1,
                              ok ? "ok" : "failed", coverage, moved))
        stage += 1
        loadedAt = nil
        let next = stage < models.count ? models[stage] : nil
        let name = sourceName
        let summary = results.joined(separator: ", ")
        let passed = allOK
        lock.unlock()

        appLog("avatar autotest: \(results.last ?? "")")
        if let next, let name {
            DispatchQueue.main.async {
                core_source_update(name, encodeJSON(["model": .string(next)]))
            }
        } else {
            appLog("avatar autotest: \(passed ? "ok" : "failed") (\(summary))")
        }
    }

    /// 표면의 BGRA 화소를 읽고 PNG로 Documents에 남긴다
    private static func snapshot(_ surface: IOSurface, name: String) -> [UInt8] {
        surface.lock(options: .readOnly, seed: nil)
        defer { surface.unlock(options: .readOnly, seed: nil) }
        let width = surface.width
        let height = surface.height
        let bytesPerRow = surface.bytesPerRow
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let base = surface.baseAddress.assumingMemoryBound(to: UInt8.self)
        for row in 0..<height {
            pixels.withUnsafeMutableBytes { buffer in
                buffer.baseAddress!.advanced(by: row * width * 4).copyMemory(from: base + row * bytesPerRow, byteCount: width * 4)
            }
        }
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = documents.appendingPathComponent("\(name).png")
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        if let provider = CGDataProvider(data: Data(pixels) as CFData),
            let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info, provider: provider,
                                decode: nil, shouldInterpolate: false, intent: .defaultIntent),
            let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        {
            CGImageDestinationAddImage(destination, image, nil)
            CGImageDestinationFinalize(destination)
        }
        return pixels
    }
}
