import Combine
import SwiftUI

/// 현재 씬의 항목 (Core/scenes.c의 core_scene_items_json)
struct SceneItem: Identifiable, Decodable, Hashable {
    let id: Int64
    let name: String
    let type: String
    let visible: Bool
    let locked: Bool
    let video: Bool
    let audio: Bool
}

struct SourceType: Identifiable, Decodable, Hashable {
    let id: String
    let name: String

    /// 자주 쓰는 종류는 한국어로
    var displayName: String {
        switch id {
        case "macos-avcapture": "카메라·캡처 장치"
        case "color_source_v3": "단색"
        case "image_source": "이미지"
        case "slideshow_v2", "slideshow": "이미지 슬라이드쇼"
        default: name
        }
    }

    var systemImage: String {
        switch id {
        case "macos-avcapture": "video"
        case "color_source_v3": "paintpalette"
        case "image_source": "photo"
        case "slideshow_v2", "slideshow": "photo.on.rectangle"
        default: "square.on.square"
        }
    }
}

/// 씬·소스 상태와 조작. 실제 일은 Core/scenes.c가 하고, 바뀌면 씬 구성을 저장한다.
final class SceneModel: ObservableObject {
    static let shared = SceneModel()

    @Published private(set) var scenes: [String] = []
    @Published private(set) var currentScene = ""
    @Published private(set) var items: [SceneItem] = []
    @Published var selection: Int64?
    /// 선택한 항목의 네 모서리 (캔버스 좌표)
    @Published private(set) var selectionBox: [CGPoint] = []

    private var saveWork: DispatchWorkItem?
    private var timer: AnyCancellable?

    private init() {
        // 카메라처럼 크기가 나중에 정해지는 소스가 있어 선택 상자는 주기적으로도 다시 읽는다
        timer = Timer.publish(every: 0.5, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.updateSelectionBox() }
    }

    // MARK: 읽기

    func refresh() {
        struct ScenesJSON: Decodable {
            struct Scene: Decodable { let name: String }
            let current: String
            let scenes: [Scene]
        }
        struct ItemsJSON: Decodable { let items: [SceneItem] }

        if let json = decodeCoreJSON(core_scenes_json(), as: ScenesJSON.self) {
            scenes = json.scenes.map(\.name)
            currentScene = json.current
        }
        items = decodeCoreJSON(core_scene_items_json(), as: ItemsJSON.self)?.items ?? []

        if let selection, !items.contains(where: { $0.id == selection }) {
            self.selection = nil
        }
        updateSelectionBox()
    }

    func updateSelectionBox() {
        guard let selection else {
            if !selectionBox.isEmpty { selectionBox = [] }
            return
        }

        var corners = [Float](repeating: 0, count: 8)
        guard core_scene_item_box(selection, &corners) else {
            selectionBox = []
            return
        }
        let box = (0..<4).map { CGPoint(x: CGFloat(corners[$0 * 2]), y: CGFloat(corners[$0 * 2 + 1])) }
        if box != selectionBox { selectionBox = box }
    }

    var selectedItem: SceneItem? {
        items.first { $0.id == selection }
    }

    var sourceTypes: [SourceType] {
        struct TypesJSON: Decodable { let types: [SourceType] }
        return decodeCoreJSON(core_source_types_json(), as: TypesJSON.self)?.types ?? []
    }

    // MARK: 씬

    func switchTo(_ scene: String) {
        core_scene_set_current(scene)
        selection = nil
        changed()
    }

    func addScene() {
        core_scene_add("장면 \(scenes.count + 1)")
        selection = nil
        changed()
    }

    func removeScene(_ scene: String) {
        core_scene_remove(scene)
        changed()
    }

    @discardableResult
    func renameScene(_ scene: String, to name: String) -> Bool {
        let ok = core_scene_rename(scene, name)
        changed()
        return ok
    }

    func moveScene(_ scene: String, by offset: Int) {
        core_scene_move(scene, Int32(offset))
        changed()
    }

    // MARK: 항목

    func select(_ id: Int64?) {
        selection = id
        updateSelectionBox()
    }

    func setVisible(_ item: SceneItem, _ visible: Bool) {
        core_scene_item_set_visible(item.id, visible)
        changed()
    }

    func setLocked(_ item: SceneItem, _ locked: Bool) {
        core_scene_item_set_locked(item.id, locked)
        changed()
    }

    enum Order: Int32 {
        case up = 0, down = 1, top = 2, bottom = 3
    }

    func order(_ item: SceneItem, _ order: Order) {
        core_scene_item_order(item.id, order.rawValue)
        changed()
    }

    func fit(_ item: SceneItem) {
        core_scene_item_fit(item.id)
        changed()
    }

    func resetTransform(_ item: SceneItem) {
        core_scene_item_reset(item.id)
        changed()
    }

    func remove(_ item: SceneItem) {
        core_scene_item_remove(item.id)
        if selection == item.id { selection = nil }
        changed()
    }

    @discardableResult
    func renameSource(_ item: SceneItem, to name: String) -> Bool {
        let ok = core_source_rename(item.name, name)
        changed()
        return ok
    }

    /// 새 소스를 넣고 그 항목을 고른다. 돌려주는 값은 새 소스의 이름
    func addSource(type: SourceType) -> String? {
        let id = core_scene_add_source(type.id, type.displayName)
        guard id >= 0 else { return nil }
        selection = id
        changed()
        return items.first { $0.id == id }?.name
    }

    // MARK: 프리뷰 터치 (캔버스 좌표)

    func item(at point: CGPoint) -> Int64? {
        let id = core_scene_item_at(Float(point.x), Float(point.y))
        return id >= 0 ? id : nil
    }

    func translateSelection(by delta: CGSize) {
        guard let item = selectedItem, !item.locked else { return }
        core_scene_item_translate(item.id, Float(delta.width), Float(delta.height))
        updateSelectionBox()
    }

    func scaleSelection(by factor: CGFloat, around point: CGPoint) {
        guard let item = selectedItem, !item.locked else { return }
        core_scene_item_scale(item.id, Float(factor), Float(point.x), Float(point.y))
        updateSelectionBox()
    }

    /// 끌기·확대가 끝났을 때
    func transformEnded() {
        setNeedsSave()
    }

    // MARK: 저장

    private func changed() {
        refresh()
        setNeedsSave()
    }

    /// 바뀐 뒤 1초 동안 더 바뀌지 않으면 저장한다
    func setNeedsSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { core_save_collection() }
        saveWork = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1, execute: work)
    }

    func saveNow() {
        saveWork?.cancel()
        core_save_collection()
    }

    // MARK: CI 시험

    /// CI용: `-autotest-scenes`로 띄우면 씬·소스 조작을 한 바퀴 돌리고 결과를 로그에 남긴다.
    /// 마지막에 "시험 장면"을 남겨 저장하므로, 다음 실행에서 씬 2개를 불러오는지 볼 수 있다.
    func runAutotestIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("-autotest-scenes") else { return }

        let firstScene = currentScene
        addScene()
        let added = currentScene
        renameScene(added, to: "시험 장면")

        let types = sourceTypes
        guard let color = types.first(where: { $0.id == "color_source_v3" }),
            let name = addSource(type: color), let item = selectedItem
        else {
            appLog("scenes autotest: failed to add a color source (types: \(types.map(\.id)))")
            return
        }

        core_source_update(name, encodeJSON(["color": .number(Double(0xFF00_80FF)), "width": .number(320), "height": .number(180)]))
        resetTransform(item)
        translateSelection(by: CGSize(width: 100, height: 50))
        scaleSelection(by: 2, around: CGPoint(x: 100, y: 50))
        let box = selectionBox
        let hit = self.item(at: CGPoint(x: 300, y: 200))

        setVisible(item, false)
        setVisible(item, true)
        setLocked(item, true)
        setLocked(item, false)
        order(item, .bottom)
        renameSource(item, to: "시험 색")
        let properties = decodeCoreJSON(core_source_properties_json("시험 색"), as: SourceProperties.self)

        // 카메라 소스의 프레임 레이트 속성이 범위와 함께 오는지 (시뮬레이터에는 카메라가 없어 범위는 비어 있다)
        var cameraFrameRate = "no camera type"
        if let camera = types.first(where: { $0.id == "macos-avcapture" }), let cameraName = addSource(type: camera),
            let cameraItem = selectedItem
        {
            let cameraProperties = decodeCoreJSON(core_source_properties_json(cameraName), as: SourceProperties.self)
            let frameRate = cameraProperties?.properties.first { $0.name == "frame_rate" }
            cameraFrameRate = frameRate.map { "ok, \($0.fps_ranges?.count ?? -1) range(s)" } ?? "missing"
            remove(cameraItem)
        }

        // 형식의 fps 범위 → 고를 수 있는 값
        let sampleChoices = FrameRateChoice.choices(
            in: [.init(min: 59.94, max: 59.94), .init(min: 1, max: 30)],
            current: FrameRateChoice(numerator: 30, denominator: 1)
        ).map(\.label)
        let choicesOK =
            sampleChoices == ["59.94 fps", "30 fps", "29.97 fps", "25 fps", "24 fps", "23.98 fps", "15 fps", "10 fps", "5 fps"]

        switchTo(firstScene)
        switchTo("시험 장면")

        // 캔버스를 한 번 바꿨다가 되돌린다 (프리뷰가 떠 있는 채로 obs_reset_video)
        let core = Core.shared
        let (width, height, fps) = (core.width, core.height, core.fps)
        let changed = core.applyCanvas(width: 1280, height: 720, fps: 30)
        let restored = core.applyCanvas(width: width, height: height, fps: fps)
        saveNow()

        // 미리보기 끄기·켜기: 디스플레이가 없어졌다가 다시 생겨야 하고, 그동안에도 출력용 캔버스는 돈다
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            UserDefaults.standard.set(false, forKey: AppSettings.previewEnabled)
            appLog("preview autotest: off")
            DispatchQueue.main.asyncAfter(deadline: .now() + 7) {
                UserDefaults.standard.set(true, forKey: AppSettings.previewEnabled)
                appLog("preview autotest: on")
            }
        }

        let status =
            !(changed && restored) ? "canvas change failed"
            : !cameraFrameRate.hasPrefix("ok") ? "camera frame rate property \(cameraFrameRate)"
            : !choicesOK ? "frame rate choices wrong \(sampleChoices)" : "ok"
        appLog(
            "scenes autotest: \(status) (scenes \(scenes), items \(items.map(\.name)), box \(box.map { "\(Int($0.x)),\(Int($0.y))" }), hit \(hit.map(String.init) ?? "none"), properties \(properties?.properties.count ?? -1), camera frame rate \(cameraFrameRate), choices \(sampleChoices))"
        )
    }
}
