// Hardware smoke test for A30Kit. Default: read everything. --writes: change + read back +
// restore sidetone (boom) and EQ mode. Never touches factory reset or DFU.
import Foundation

@main
struct Probe {
    static func main() {
        Task { @MainActor in
            let a = A30()
            var origST: Int?
            var origEQ: EQSetting?
            do {
                try await a.connect()
                print("battery", try await a.battery())
                print("name", try await a.name(), "fw", try await a.firmware(), "serial", try await a.serial())
                print("volume", try await a.volume(), "eq", try await a.eq(), "modes", hex(try await a.eqModes()))
                print("sidetone", try await a.sidetone(), "noiseGate", try await a.noiseGate())
                print("balance", try await a.balance(), "dongle", try await a.dongle())
                print("sleep", try await a.sleepTimer(), "tones", try await a.tones())
                if CommandLine.arguments.contains("--writes") {
                    if let st = try await a.sidetone()[.boom] {
                        origST = st
                        try await a.setSidetone(.boom, st == 30 ? 40 : 30)
                        print("sidetone after set", try await a.sidetone())
                        try await a.setSidetone(.boom, st)
                        print("sidetone restored", try await a.sidetone())
                    } else {
                        print("boom sidetone not readable: sidetone write test skipped")
                    }
                    let eq = try await a.eq()
                    origEQ = eq
                    try await a.setEQ(EQSetting(mode: EQMode.footstep.rawValue, bands: [0, 0, 0, 0, 0]), switching: true)
                    print("eq after set", try await a.eq())
                    try await a.setEQ(eq, switching: true)
                    print("eq restored", try await a.eq())
                    let bal = try await a.balance()
                    do { try await a.setBalance(bal) } catch { print("balance set ->", error) }
                }
                print("PROBE OK")
                exit(0)
            } catch {
                print("PROBE ERROR", error)
                if let s = origST { try? await a.setSidetone(.boom, s) }
                if let e = origEQ { try? await a.setEQ(e, switching: true) }
                exit(1)
            }
        }
        RunLoop.main.run()   // IOBluetooth callbacks need the main run loop
    }
}
