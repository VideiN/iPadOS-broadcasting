import SwiftUI
import UniformTypeIdentifiers

/// 소스 속성 (Core/scenes.c의 core_source_properties_json). libobs의 obs_properties를 그대로 옮긴 것이다.
struct SourceProperties: Decodable {
    let type: String
    let properties: [SourceProperty]
    let settings: [String: JSONValue]
}

struct SourceProperty: Decodable, Identifiable {
    struct ListItem: Decodable, Hashable {
        let name: String
        let disabled: Bool
        let value: JSONValue
    }

    /// 프레임 레이트 속성이 허용하는 범위 (초당 프레임)
    struct FrameRateRange: Decodable, Hashable {
        let min: Double
        let max: Double
    }

    let name: String
    let type: String
    let label: String
    let help: String
    let group: String
    let enabled: Bool
    let visible: Bool
    let min: Double?
    let max: Double?
    let step: Double?
    let suffix: String?
    let text_type: Int?
    let path_type: Int?
    let filter: String?
    let format: String?
    let items: [ListItem]?
    let fps_ranges: [FrameRateRange]?
    /// editable_list: 0 문자열, 1 파일, 2 파일과 URL
    let list_type: Int?

    var id: String { name }
}

/// 프레임 레이트 값. obs_data에는 {"numerator": n, "denominator": d}로 들어간다 (obs_data_set_frames_per_second)
struct FrameRateChoice: Hashable {
    let numerator: Int
    let denominator: Int

    var fps: Double { Double(numerator) / Double(denominator) }

    var label: String {
        denominator == 1 ? "\(numerator) fps" : String(format: "%.2f fps", fps)
    }

    var json: JSONValue {
        .object(["numerator": .number(Double(numerator)), "denominator": .number(Double(denominator))])
    }

    init(numerator: Int, denominator: Int) {
        self.numerator = numerator
        self.denominator = denominator
    }

    init?(_ value: JSONValue?) {
        guard case .object(let object) = value, let numerator = object["numerator"]?.number,
            let denominator = object["denominator"]?.number, numerator > 0, denominator > 0
        else { return nil }
        self.init(numerator: Int(numerator), denominator: Int(denominator))
    }

    private static let common: [FrameRateChoice] = [
        .init(numerator: 240, denominator: 1), .init(numerator: 120, denominator: 1),
        .init(numerator: 60, denominator: 1), .init(numerator: 60000, denominator: 1001),
        .init(numerator: 50, denominator: 1), .init(numerator: 48, denominator: 1),
        .init(numerator: 30, denominator: 1), .init(numerator: 30000, denominator: 1001),
        .init(numerator: 25, denominator: 1), .init(numerator: 24, denominator: 1),
        .init(numerator: 24000, denominator: 1001), .init(numerator: 15, denominator: 1),
        .init(numerator: 10, denominator: 1), .init(numerator: 5, denominator: 1),
    ]

    /// 범위 안에 드는 흔한 값들, 높은 것부터. 지금 값이 목록에 없으면 함께 넣는다.
    static func choices(in ranges: [SourceProperty.FrameRateRange], current: FrameRateChoice?) -> [FrameRateChoice] {
        var result = common.filter { choice in
            ranges.contains { $0.min - 0.01 <= choice.fps && choice.fps <= $0.max + 0.01 }
        }
        if let current, !result.contains(where: { abs($0.fps - current.fps) < 0.001 }) {
            result.append(current)
        }
        return result.sorted { $0.fps > $1.fps }
    }
}

/// 어떤 소스든 그 속성으로 만드는 설정 화면 (Qt 속성 창 대신)
struct SourcePropertiesView: View {
    let sourceName: String
    /// 소리가 있는 소스면 맨 위에 오디오 필터로 가는 줄을 둔다 (필터 자신의 설정 화면에서는 끈다)
    var showsFilters = false
    var onChange: () -> Void = {}

    @State private var properties: SourceProperties?
    @State private var pickingPathFor: SourceProperty?
    /// 이 소스의 필터 수. 소리가 없는 소스면 nil
    @State private var filterCount: Int?

    var body: some View {
        Form {
            if let filterCount {
                Section {
                    NavigationLink {
                        FiltersView(sourceName: sourceName, onChange: onChange)
                            .navigationTitle("오디오 필터")
                            .navigationBarTitleDisplayMode(.inline)
                    } label: {
                        LabeledContent {
                            Text(filterCount == 0 ? "없음" : "\(filterCount)개")
                        } label: {
                            Label("오디오 필터", systemImage: "waveform")
                        }
                    }
                }
            }
            if let properties {
                let visible = properties.properties.filter(\.visible)
                if visible.isEmpty {
                    Text("바꿀 수 있는 설정이 없습니다.").foregroundStyle(.secondary)
                }
                ForEach(groups(visible), id: \.name) { group in
                    Section(group.name) {
                        ForEach(group.properties.filter { $0.type != "editable_list" }) { property in
                            row(property, settings: properties.settings)
                                .disabled(!property.enabled)
                        }
                    }
                    // 목록(슬라이드쇼의 이미지 파일 등)은 따로 한 칸
                    ForEach(group.properties.filter { $0.type == "editable_list" }) { property in
                        editableList(property, value: properties.settings[property.name])
                            .disabled(!property.enabled)
                    }
                }
            } else {
                ProgressView()
            }
        }
        .onAppear {
            reload()
            reloadFilterCount()
        }
        .fileImporter(
            isPresented: Binding(get: { pickingPathFor != nil }, set: { if !$0 { pickingPathFor = nil } }),
            allowedContentTypes: allowedTypes(pickingPathFor),
            allowsMultipleSelection: pickingPathFor?.type == "editable_list"
        ) { result in
            guard let property = pickingPathFor, case .success(let urls) = result, !urls.isEmpty else { return }
            let images = allowedTypes(property) == [.image]
            let copies = urls.compactMap { images ? Self.importImage($0) : Self.importFile($0) }
            if property.type == "editable_list" {
                appendToList(property, copies)
            } else if let copy = copies.first {
                update(property.name, .string(copy.path))
            }
        }
    }

    // MARK: 행

    @ViewBuilder
    private func row(_ property: SourceProperty, settings: [String: JSONValue]) -> some View {
        let value = settings[property.name]

        switch property.type {
        case "bool":
            Toggle(
                property.label,
                isOn: Binding(get: { value?.bool ?? false }, set: { update(property.name, .bool($0)) }))

        case "int", "float":
            NumberRow(property: property, value: value?.number ?? 0) { update(property.name, .number($0)) }

        case "text":
            switch property.text_type ?? 0 {
            case 3:  // OBS_TEXT_INFO
                Text(property.label).font(.footnote).foregroundStyle(.secondary)
            case 1:  // OBS_TEXT_PASSWORD
                CommitTextField(label: property.label, text: value?.string ?? "", secure: true) {
                    update(property.name, .string($0))
                }
            case 2:  // OBS_TEXT_MULTILINE
                MultilineTextRow(label: property.label, text: value?.string ?? "") {
                    update(property.name, .string($0))
                }
            default:
                CommitTextField(label: property.label, text: value?.string ?? "", secure: false) {
                    update(property.name, .string($0))
                }
            }

        case "path":
            HStack {
                VStack(alignment: .leading) {
                    Text(property.label)
                    let path = value?.string ?? ""
                    Text(path.isEmpty ? "선택 안 함" : URL(fileURLWithPath: path).lastPathComponent)
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Spacer()
                if allowedTypes(property) == [.image] {
                    PhotoImportButton(title: "사진 선택…", multiple: false) { urls in
                        update(property.name, .string(urls[0].path))
                    }
                }
                Button("파일 선택…") { pickingPathFor = property }
            }
            // 버튼이 둘이라 줄 전체가 한 버튼처럼 눌리지 않게
            .buttonStyle(.borderless)

        case "list":
            Picker(
                property.label,
                selection: Binding(get: { value ?? .null }, set: { update(property.name, $0) })
            ) {
                ForEach(property.items ?? [], id: \.self) { item in
                    Text(item.name).tag(item.value).selectionDisabled(item.disabled)
                }
            }

        case "color", "color_alpha":
            ColorPicker(
                property.label,
                selection: Binding(
                    get: { Self.color(fromABGR: value?.number ?? 0) },
                    set: { update(property.name, .number(Self.abgr(from: $0))) }),
                supportsOpacity: property.type == "color_alpha")

        case "button":
            Button(property.label) {
                core_source_press_button(sourceName, property.name)
                reload()
            }

        case "frame_rate":
            let current = FrameRateChoice(value)
            let choices = FrameRateChoice.choices(in: property.fps_ranges ?? [], current: current)
            if choices.isEmpty {
                LabeledContent(property.label) {
                    Text("입력 형식을 먼저 고르세요").font(.footnote).foregroundStyle(.secondary)
                }
            } else {
                Picker(
                    property.label,
                    selection: Binding(
                        get: { choices.first { choice in current.map { abs($0.fps - choice.fps) < 0.001 } ?? false } },
                        set: { if let choice = $0 { update(property.name, choice.json) } })
                ) {
                    if current == nil {
                        Text("선택 안 함").tag(FrameRateChoice?.none)
                    }
                    ForEach(choices, id: \.self) { choice in
                        Text(choice.label).tag(Optional(choice))
                    }
                }
            }

        default:
            LabeledContent(property.label) {
                Text("앱에서 아직 바꿀 수 없음").font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    /// 편집 가능한 목록. 값은 [{"value": 경로, "hidden", "selected"}] (obs_data 배열)
    @ViewBuilder
    private func editableList(_ property: SourceProperty, value: JSONValue?) -> some View {
        let entries = Self.listEntries(value)
        let files = (property.list_type ?? 0) != 0

        Section {
            if entries.isEmpty {
                Text("비어 있음").foregroundStyle(.secondary)
            }
            ForEach(Array(entries.enumerated()), id: \.offset) { index, entry in
                let path = Self.listPath(entry)
                HStack {
                    Text(files ? URL(fileURLWithPath: path).lastPathComponent : path).lineLimit(1)
                    Spacer()
                    if files && !FileManager.default.fileExists(atPath: path) {
                        Text("파일 없음").font(.footnote).foregroundStyle(.red)
                    }
                }
                .contextMenu {
                    Button("위로", systemImage: "chevron.up") { moveInList(property, entries, index, by: -1) }
                        .disabled(index == 0)
                    Button("아래로", systemImage: "chevron.down") { moveInList(property, entries, index, by: 1) }
                        .disabled(index == entries.count - 1)
                    Divider()
                    Button("삭제", systemImage: "trash", role: .destructive) {
                        var remaining = entries
                        remaining.remove(at: index)
                        update(property.name, .array(remaining))
                    }
                }
            }
            .onDelete { offsets in
                var remaining = entries
                remaining.remove(atOffsets: offsets)
                update(property.name, .array(remaining))
            }

            if files {
                HStack {
                    if allowedTypes(property) == [.image] {
                        PhotoImportButton(title: "사진 추가…", multiple: true) { appendToList(property, $0) }
                    }
                    Spacer()
                    Button("파일 추가…") { pickingPathFor = property }
                }
                .buttonStyle(.borderless)
            }
        } header: {
            Text(property.label)
        } footer: {
            Text(files ? "위에서부터 차례로 나옵니다. 밀어서 지우고, 길게 눌러 순서를 바꿉니다." : "앱에서는 항목을 지우거나 순서만 바꿀 수 있습니다.")
        }
    }

    private static func listEntries(_ value: JSONValue?) -> [JSONValue] {
        if case .array(let entries) = value { return entries }
        return []
    }

    private static func listPath(_ entry: JSONValue) -> String {
        if case .object(let object) = entry { return object["value"]?.string ?? "" }
        return entry.string ?? ""
    }

    private func appendToList(_ property: SourceProperty, _ urls: [URL]) {
        let settings = properties?.settings ?? [:]
        let added = urls.map { JSONValue.object(["value": .string($0.path), "hidden": .bool(false), "selected": .bool(false)]) }
        update(property.name, .array(Self.listEntries(settings[property.name]) + added))
    }

    private func moveInList(_ property: SourceProperty, _ entries: [JSONValue], _ index: Int, by offset: Int) {
        let target = index + offset
        guard entries.indices.contains(target) else { return }
        var moved = entries
        moved.swapAt(index, target)
        update(property.name, .array(moved))
    }

    // MARK: 동작

    private func reload() {
        properties = decodeCoreJSON(core_source_properties_json(sourceName), as: SourceProperties.self)
    }

    /// 필터 화면에서 돌아올 때도 onAppear로 다시 센다
    private func reloadFilterCount() {
        guard showsFilters,
            let types = decodeCoreJSON(core_filter_types_json(sourceName), as: FilterTypes.self)?.types,
            !types.isEmpty
        else {
            filterCount = nil
            return
        }
        filterCount = decodeCoreJSON(core_filters_json(sourceName), as: SourceFilters.self)?.filters.count ?? 0
    }

    /// 바뀐 값 하나만 보낸다. 속성 목록은 설정에 따라 바뀔 수 있어 다시 읽는다 (예: 카메라 장치 → 형식 목록)
    private func update(_ name: String, _ value: JSONValue) {
        core_source_update(sourceName, encodeJSON([name: value]))
        reload()
        onChange()
    }

    private struct Group {
        let name: String
        let properties: [SourceProperty]
    }

    private func groups(_ properties: [SourceProperty]) -> [Group] {
        var result: [Group] = []
        for property in properties {
            if let last = result.last, last.name == property.group {
                result[result.count - 1] = Group(name: last.name, properties: last.properties + [property])
            } else {
                result.append(Group(name: property.group, properties: [property]))
            }
        }
        return result
    }

    private func allowedTypes(_ property: SourceProperty?) -> [UTType] {
        let filter = property?.filter?.lowercased() ?? ""
        if filter.contains("png") || filter.contains("jpg") || filter.contains("image") {
            return [.image]
        }
        if filter.contains("mp4") || filter.contains("mov") || filter.contains("media") {
            return [.movie, .audio]
        }
        return [.item]
    }

    /// 고른 파일을 Documents/Media로 복사한다. 원본 위치의 접근 권한은 앱을 다시 켜면 사라지기 때문이다.
    static func importFile(_ url: URL) -> URL? {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        let destination = MediaFolder.uniqueURL(base: url.deletingPathExtension().lastPathComponent, ext: url.pathExtension)

        do {
            try FileManager.default.copyItem(at: url, to: destination)
            appLog("imported \(url.lastPathComponent) to Documents/Media")
            return destination
        } catch {
            appLog("import failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// 이미지 파일은 사진 보관함과 같은 길로 (HEIC 등은 JPEG/PNG로 바꿔 저장)
    static func importImage(_ url: URL) -> URL? {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        guard let data = try? Data(contentsOf: url) else {
            appLog("import failed: cannot read \(url.lastPathComponent)")
            return nil
        }
        return PhotoImport.save(data, base: url.deletingPathExtension().lastPathComponent)
    }

    // MARK: 색 (libobs는 0xAABBGGRR)

    static func color(fromABGR value: Double) -> Color {
        let raw = UInt32(truncatingIfNeeded: Int64(value))
        let red = Double(raw & 0xFF) / 255
        let green = Double((raw >> 8) & 0xFF) / 255
        let blue = Double((raw >> 16) & 0xFF) / 255
        let alpha = Double((raw >> 24) & 0xFF) / 255
        return Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
    }

    static func abgr(from color: Color) -> Double {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: &alpha)

        func byte(_ component: CGFloat) -> UInt32 { UInt32((min(max(component, 0), 1) * 255).rounded()) }
        let raw = byte(red) | byte(green) << 8 | byte(blue) << 16 | byte(alpha) << 24
        return Double(raw)
    }
}

/// 정수·실수 속성: 범위가 좁으면 슬라이더, 넓으면 입력칸
private struct NumberRow: View {
    let property: SourceProperty
    let value: Double
    let commit: (Double) -> Void

    @State private var text = ""
    @State private var sliderValue: Double = 0

    var body: some View {
        let low = property.min ?? 0
        let high = property.max ?? 100
        let step = max(property.step ?? 1, property.type == "int" ? 1 : 0.0001)
        let suffix = property.suffix ?? ""

        if high - low <= 1000, high > low {
            VStack(alignment: .leading) {
                HStack {
                    Text(property.label)
                    Spacer()
                    Text(format(sliderValue) + suffix).foregroundStyle(.secondary).monospacedDigit()
                }
                Slider(value: $sliderValue, in: low...high, step: step) { editing in
                    if !editing { commit(sliderValue) }
                }
            }
            .onAppear { sliderValue = value }
            .onChange(of: value) { _, newValue in sliderValue = newValue }
        } else {
            HStack {
                Text(property.label)
                Spacer()
                TextField("", text: $text)
                    .keyboardType(property.type == "int" ? .numberPad : .decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 120)
                    .onSubmit { submit(low: low, high: high) }
                Text(suffix).foregroundStyle(.secondary)
            }
            .onAppear { text = format(value) }
            .onChange(of: value) { _, newValue in text = format(newValue) }
        }
    }

    private func submit(low: Double, high: Double) {
        guard let number = Double(text) else { return }
        commit(min(max(number, low), high))
    }

    private func format(_ number: Double) -> String {
        property.type == "int" ? String(Int(number.rounded())) : String(format: "%.2f", number)
    }
}

/// 입력을 마칠 때(리턴) 반영하는 문자열 칸
/// 여러 줄 글 (텍스트 소스의 글 등). 줄바꿈을 넣을 수 있게 "적용"을 눌러야 반영된다 (화면을 닫아도 반영)
private struct MultilineTextRow: View {
    let label: String
    let text: String
    let commit: (String) -> Void

    @State private var editing = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
            TextEditor(text: $editing)
                .frame(minHeight: 90)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
            Button("적용") { commit(editing) }
                .disabled(editing == text)
        }
        .onAppear { editing = text }
        .onDisappear { if editing != text { commit(editing) } }
    }
}

private struct CommitTextField: View {
    let label: String
    let text: String
    let secure: Bool
    let commit: (String) -> Void

    @State private var editing = ""

    var body: some View {
        Group {
            if secure {
                SecureField(label, text: $editing)
            } else {
                TextField(label, text: $editing)
            }
        }
        .onSubmit { commit(editing) }
        .onAppear { editing = text }
    }
}
