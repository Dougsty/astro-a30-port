// Minimal test runner: XCTest / swift-testing are unavailable without Xcode.
import Foundation

var failures = 0

func check(_ cond: @autoclosure () -> Bool, _ msg: String, line: Int = #line) {
    if !cond() { failures += 1; print("FAIL line \(line): \(msg)") }
}

/// "13 a0 05" -> [0x13, 0xa0, 0x05]
func bytes(_ s: String) -> [UInt8] {
    s.split(separator: " ").map { UInt8($0, radix: 16)! }
}

@main
struct SelfTest {
    static func main() {
        testFraming()
        testIAP2()
        testCodecs()
        print(failures == 0 ? "selftest: all passed" : "selftest: \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
