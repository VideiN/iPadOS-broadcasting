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

    var id: String { name }
}

/// 어떤 소스든 그 속성으로 만드는 설정 화면 (Qt 속성 창 대신)
struct SourcePropertiesView: View {
    let sourceName: String
    var onChange: () -> Void = {}

    @State private var properties: SourceProperties?
    @State private var pickingPathFor: SourceProperty?

    var body: some View {
        Form {
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
        .onAppear(perform: reload)
        .fileImporter(
            isPresented: Binding(get: { pickingPathFor != nil }, set: { if !$0 { pickingPathFor = nil } }),
            allowedContentTypes: allowedTypes(pickingPathFor),
            allowsMultipleSelection: false
        ) { result in
            guard let property = pickingPathFor, case .success(let urls) = result, let url = urls.first else { return }
            if let copy = Self.importFile(url) {
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
                Button("파일 선택…") { pickingPathFor = property }
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
