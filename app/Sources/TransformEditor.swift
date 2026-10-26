import SwiftUI

/// 변형 편집 (P11, OBS의 "변형 편집"): 위치·회전·크기·자르기를 숫자로. 고치는 즉시 캔버스에 반영한다
struct TransformEditor: View {
    @ObservedObject var model: SceneModel
    let item: SceneItem

    @State private var value: SceneModel.Transform?
    @State private var keepAspect = true

    var body: some View {
        Form {
            if let value {
                Section("위치 (캔버스 픽셀)") {
                    number("X", value.x) { self.value?.x = $0 }
                    number("Y", value.y) { self.value?.y = $0 }
                }
                Section {
                    number("회전 (도)", value.rotation) { self.value?.rotation = $0 }
                    HStack {
                        Button("왼쪽 90°") { self.value?.rotation = normalized(value.rotation - 90) }
                        Spacer()
                        Button("0°") { self.value?.rotation = 0 }
                        Spacer()
                        Button("오른쪽 90°") { self.value?.rotation = normalized(value.rotation + 90) }
                    }
                    .buttonStyle(.borderless)
                } header: {
                    Text("회전")
                } footer: {
                    Text("정렬점(위치)을 기준으로 돕니다. 미리보기의 회전 핸들과 90° 버튼은 가운데를 기준으로 돕니다.")
                }
                Section {
                    number("폭", value.width) { width in
                        if keepAspect, value.width > 0 { self.value?.height = (width * value.height / value.width).rounded() }
                        self.value?.width = width
                    }
                    number("높이", value.height) { height in
                        if keepAspect, value.height > 0 { self.value?.width = (height * value.width / value.height).rounded() }
                        self.value?.height = height
                    }
                    Toggle("비율 유지", isOn: $keepAspect)
                } header: {
                    Text(value.bounded ? "크기 (바운드)" : "크기")
                } footer: {
                    Text("원본 \(value.sourceWidth)×\(value.sourceHeight)")
                }
                Section {
                    integer("위", value.cropTop) { self.value?.cropTop = $0 }
                    integer("아래", value.cropBottom) { self.value?.cropBottom = $0 }
                    integer("왼쪽", value.cropLeft) { self.value?.cropLeft = $0 }
                    integer("오른쪽", value.cropRight) { self.value?.cropRight = $0 }
                    Button("자르기 없애기") {
                        self.value?.cropTop = 0
                        self.value?.cropBottom = 0
                        self.value?.cropLeft = 0
                        self.value?.cropRight = 0
                    }
                } header: {
                    Text("자르기 (원본 픽셀)")
                }
                Section {
                    Button("원래대로 (크기·회전·자르기)", role: .destructive) {
                        model.resetTransform(item)
                        self.value = model.transform(of: item)
                    }
                }
            } else {
                Text("이 소스를 찾을 수 없습니다.")
            }
        }
        .onAppear { value = model.transform(of: item) }
        .onChange(of: value) { old, new in
            guard let old, let new, old != new else { return }
            model.setTransform(item, clamped(new))
        }
    }

    private func normalized(_ degrees: Double) -> Double {
        let angle = degrees.truncatingRemainder(dividingBy: 360)
        return angle < 0 ? angle + 360 : angle
    }

    /// 자르기는 원본보다 크게 할 수 없다 (남는 크기 1픽셀 이상)
    private func clamped(_ value: SceneModel.Transform) -> SceneModel.Transform {
        var value = value
        value.cropLeft = min(max(value.cropLeft, 0), max(value.sourceWidth - 1, 0))
        value.cropRight = min(max(value.cropRight, 0), max(value.sourceWidth - value.cropLeft - 1, 0))
        value.cropTop = min(max(value.cropTop, 0), max(value.sourceHeight - 1, 0))
        value.cropBottom = min(max(value.cropBottom, 0), max(value.sourceHeight - value.cropTop - 1, 0))
        value.width = max(value.width, 1)
        value.height = max(value.height, 1)
        return value
    }

    private func number(_ title: String, _ current: Double, set: @escaping (Double) -> Void) -> some View {
        LabeledContent(title) {
            TextField(
                title, value: Binding(get: { current }, set: set), format: .number.precision(.fractionLength(0...2))
            )
            .keyboardType(.numbersAndPunctuation)
            .multilineTextAlignment(.trailing)
            .frame(maxWidth: 140)
        }
    }

    private func integer(_ title: String, _ current: Int, set: @escaping (Int) -> Void) -> some View {
        LabeledContent(title) {
            TextField(title, value: Binding(get: { current }, set: set), format: .number)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 140)
        }
    }
}
