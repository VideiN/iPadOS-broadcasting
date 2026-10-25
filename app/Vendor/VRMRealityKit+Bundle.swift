import Foundation

// SwiftPM이 리소스가 있는 타깃에 만들어 주는 Bundle.module 대신 (CMake로 빌드한다, app/CMakeLists.txt).
// MToon 셰이더(MToon-ios.metallib / MToon-iossim.metallib)는 앱 번들에 복사한다
extension Bundle {
    static var module: Bundle { .main }
}
