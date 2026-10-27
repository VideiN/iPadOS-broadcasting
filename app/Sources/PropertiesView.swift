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
    @State private var showingImporter = false
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
                        ForEach(group.properties) { property in
                            row(property, settings: properties.settings)
                                .disabled(!property.enabled)
                        }
                    }
                }
            } else {
                ProgressView()
            }
        }
        .onAppear {
            appLog("properties: shown for '\(sourceName)'")
            reload()
            reloadFilterCount()
        }
        .onChange(of: showingImporter) { _, shown in
            appLog("file picker: \(shown ? "presented" : "closed")")
        }
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: allowedTypes(pickingPathFor),
            allowsMultipleSelection: false
        ) { result in
            // 창이 닫힐 때(isPresented = false) 이 처리기보다 먼저 불리므로 고른 속성은 여기서 지운다.
            // 예전에는 닫히면서 지워져 파일을 골라도 아무것도 바뀌지 않았다 (로그도 없이)
            let property = pickingPathFor
            pickingPathFor = nil
            guard let property else {
                appLog("file picker: no property to set")
                return
            }
            switch result {
            case .success(let urls):
                guard let url = urls.first else {
                    appLog("file picker: nothing chosen for '\(property.name)'")
                    return
                }
                appLog("file picker: '\(property.name)' ← \(url.lastPathComponent)")
                if let copy = Self.importFile(url) {
                    update(property.name, .string(copy.path))
                }
            case .failure(let error):
                appLog("file picker: failed for '\(property.name)': \(error.localizedDescription)")
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
                Button("파일 선택…") {
                    // 창이 안 뜨거나 고른 뒤 아무 일도 없을 때 어디서 멈췄는지 보이게 (P13 실기기 문의)
                    appLog(
                        "file picker: opening for '\(property.name)' of '\(sourceName)' "
                            + "(types \(allowedTypes(property).map(\.identifier).joined(separator: ",")))")
                    pickingPathFor = property
                    showingImporter = true
                }
            }

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
        // 필터의 확장자(예: "VRM (*.vrm)")로. .item은 폴더도 포함해 아이패드 파일 선택 창이 고른 파일을 열지 못하고
        // "열기"가 꺼진 채로 남았다 (P13 실기기: VRM을 골라도 확인이 안 눌림). 파일만(.data)
        var types: [UTType] = []
        if let regex = try? NSRegularExpression(pattern: #"\*\.([A-Za-z0-9]+)"#) {
            let range = NSRange(filter.startIndex..., in: filter)
            for match in regex.matches(in: filter, range: range) {
                if let extRange = Range(match.range(at: 1), in: filter),
                    let type = UTType(filenameExtension: String(filter[extRange]), conformingTo: .data)
                {
                    types.append(type)
                }
            }
        }
        return types + [.data]
    }

    /// 고른 파일을 Documents/Media로 복사한다. 원본 위치의 접근 권한은 앱을 다시 켜면 사라지기 때문이다.
    static func importFile(_ url: URL) -> URL? {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let directory = documents.appendingPathComponent("Media", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var destination = directory.appendingPathComponent(url.lastPathComponent)
        var counter = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            let base = url.deletingPathExtension().lastPathComponent
            destination = directory.appendingPathComponent("\(base) \(counter)").appendingPathExtension(url.pathExtension)
            counter += 1
        }

        do {
            try FileManager.default.copyItem(at: url, to: destination)
            appLog("imported \(url.lastPathComponent) to Documents/Media")
            return destination
        } catch {
            appLog("import failed: \(error.localizedDescription)")
            return nil
        }
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
