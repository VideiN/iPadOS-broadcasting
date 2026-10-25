// VRMKit이 쓰는 swift-simd-compat(tattn, MIT)의 Apple 플랫폼 쪽과 같다: simd를 그대로 내보낸다.
// SwiftPM 대신 CMake로 빌드하므로 패키지를 받지 않고 이 한 줄로 둔다 (app/CMakeLists.txt)
@_exported public import simd
