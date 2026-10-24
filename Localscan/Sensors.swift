// Localscan — монітор локальних серверів у рядку меню macOS.
// Copyright (C) 2026 Golens
//
// Вільна програма: ви можете поширювати й змінювати її на умовах
// GNU General Public License версії 3 або, на ваш вибір, будь-якої
// пізнішої версії. Повний текст — у файлі LICENSE.
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import IOKit

// Два джерела температури (обидва не є публічним API Apple, тому додаток не для App Store):
// 1. SMC (AppleSMC) — окремі датчики ядер CPU і GPU, розрахункова температура поверхні корпусу,
//    SSD, акумулятор. Те саме читають Stats, iStat Menus, TG Pro.
// 2. IOHIDEventSystem — датчики кристала «PMU tdie». Резерв, якщо SMC недоступний.

// MARK: - SMC

nonisolated private struct SMCVersion { var major: UInt8 = 0; var minor: UInt8 = 0; var build: UInt8 = 0; var reserved: UInt8 = 0; var release: UInt16 = 0 }
nonisolated private struct SMCPLimit { var version: UInt16 = 0; var length: UInt16 = 0; var cpuPLimit: UInt32 = 0; var gpuPLimit: UInt32 = 0; var memPLimit: UInt32 = 0 }
// 12 байт, як у C: Swift не вирівнює вкладену структуру сам, тому три байти доповнення явно
nonisolated private struct SMCKeyInfo { var dataSize: UInt32 = 0; var dataType: UInt32 = 0; var dataAttributes: UInt8 = 0; var pad0: UInt8 = 0; var pad1: UInt8 = 0; var pad2: UInt8 = 0 }
private typealias SMCBytes = (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                              UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)
/// Рівно 80 байт — стільки очікує ядро (SMCKeyData_t)
nonisolated private struct SMCParam {
    var key: UInt32 = 0
    var vers = SMCVersion()
    var pLimit = SMCPLimit()
    var keyInfo = SMCKeyInfo()
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: SMCBytes = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
}

nonisolated private enum SMC {
    private struct Key { let name: String; let code: UInt32; let size: Int; let type: String }

    private static let conn: io_connect_t = {
        guard MemoryLayout<SMCParam>.size == 80 else { return 0 }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return 0 }
        var c: io_connect_t = 0
        let ok = IOServiceOpen(service, task_self_trap(), 0, &c) == kIOReturnSuccess
        IOObjectRelease(service)
        return ok ? c : 0
    }()

    /// Кеш температурних ключів; читається лише з фонового сканування (не паралельно)
    nonisolated(unsafe) private static var keys: [Key]?

    private static func fourCC(_ s: String) -> UInt32 { s.utf8.reduce(0) { $0 << 8 | UInt32($1) } }
    private static func name(_ v: UInt32) -> String {
        String(bytes: [UInt8(v >> 24 & 0xff), UInt8(v >> 16 & 0xff), UInt8(v >> 8 & 0xff), UInt8(v & 0xff)], encoding: .ascii) ?? "????"
    }

    private static func call(_ input: SMCParam) -> SMCParam? {
        guard conn != 0 else { return nil }
        var inp = input, out = SMCParam(), outSize = MemoryLayout<SMCParam>.size
        let r = IOConnectCallStructMethod(conn, 2, &inp, MemoryLayout<SMCParam>.size, &out, &outSize)
        return (r == kIOReturnSuccess && out.result == 0) ? out : nil
    }

    private static func keyInfo(_ code: UInt32) -> (size: Int, type: String)? {
        var p = SMCParam(); p.key = code; p.data8 = 9
        guard let o = call(p) else { return nil }
        return (Int(o.keyInfo.dataSize), name(o.keyInfo.dataType))
    }

    private static func readBytes(_ code: UInt32, _ size: Int) -> [UInt8]? {
        var p = SMCParam(); p.key = code; p.keyInfo.dataSize = UInt32(size); p.data8 = 5
        guard let o = call(p) else { return nil }
        return withUnsafeBytes(of: o.bytes) { Array($0.prefix(size)) }
    }

    private static func keyAt(_ i: UInt32) -> UInt32? {
        var p = SMCParam(); p.data8 = 8; p.data32 = i
        return call(p)?.key
    }

    private static func decode(_ b: [UInt8], _ type: String) -> Double? {
        switch type {
        case "flt ": return b.count == 4 ? Double(b.withUnsafeBytes { $0.loadUnaligned(as: Float.self) }) : nil
        case "sp78": return b.count == 2 ? Double(Int16(bitPattern: UInt16(b[0]) << 8 | UInt16(b[1]))) / 256 : nil
        default: return nil
        }
    }

    /// Перший виклик перебирає всі ключі SMC (~2500) і запам'ятовує температурні; далі читаються лише вони
    private static func temperatureKeys() -> [Key] {
        if let keys { return keys }
        var found: [Key] = []
        if let b = readBytes(fourCC("#KEY"), 4), b.count == 4 {
            let total = UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3])
            for i in 0..<min(total, 10_000) {
                guard let code = keyAt(i) else { continue }
                let n = name(code)
                guard n.hasPrefix("T"), let info = keyInfo(code), info.type == "flt " || info.type == "sp78" else { continue }
                found.append(Key(name: n, code: code, size: info.size, type: info.type))
            }
        }
        keys = found
        return found
    }

    /// Усі температурні датчики з правдоподібними значеннями
    static func readAll() -> [String: Double] {
        var out: [String: Double] = [:]
        for k in temperatureKeys() {
            guard let b = readBytes(k.code, k.size), let v = decode(b, k.type), v > 5, v < 130 else { continue }
            out[k.name] = v
        }
        return out
    }
}

// MARK: - IOHID (резерв)

@_silgen_name("IOHIDEventSystemClientCreate")
nonisolated private func IOHIDEventSystemClientCreate(_ allocator: CFAllocator?) -> Unmanaged<CFTypeRef>?
@_silgen_name("IOHIDEventSystemClientSetMatching")
nonisolated private func IOHIDEventSystemClientSetMatching(_ client: CFTypeRef, _ matching: CFDictionary) -> Int32
@_silgen_name("IOHIDEventSystemClientCopyServices")
nonisolated private func IOHIDEventSystemClientCopyServices(_ client: CFTypeRef) -> Unmanaged<CFArray>?
@_silgen_name("IOHIDServiceClientCopyProperty")
nonisolated private func IOHIDServiceClientCopyProperty(_ service: CFTypeRef, _ key: CFString) -> Unmanaged<CFTypeRef>?
@_silgen_name("IOHIDServiceClientCopyEvent")
nonisolated private func IOHIDServiceClientCopyEvent(_ service: CFTypeRef, _ type: Int64, _ options: Int32, _ timestamp: Int64) -> Unmanaged<CFTypeRef>?
@_silgen_name("IOHIDEventGetFloatValue")
nonisolated private func IOHIDEventGetFloatValue(_ event: CFTypeRef, _ field: Int32) -> Double

nonisolated private let kEventTypeTemperature: Int64 = 15
nonisolated private let kFieldTemperatureLevel: Int32 = 15 << 16

nonisolated private enum HID {
    // IOKit-хендл, який читається лише з фонового сканування (не паралельно)
    nonisolated(unsafe) private static let client: CFTypeRef? = {
        guard let c = IOHIDEventSystemClientCreate(kCFAllocatorDefault)?.takeRetainedValue() else { return nil }
        let matching: [String: Any] = ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5]
        _ = IOHIDEventSystemClientSetMatching(c, matching as CFDictionary)
        return c
    }()

    static func readAll() -> [String: Double] {
        var out: [String: Double] = [:]
        guard let client, let services = IOHIDEventSystemClientCopyServices(client)?.takeRetainedValue() as? [CFTypeRef] else { return out }
        for s in services {
            guard let name = IOHIDServiceClientCopyProperty(s, "Product" as CFString)?.takeRetainedValue() as? String,
                  let ev = IOHIDServiceClientCopyEvent(s, kEventTypeTemperature, 0, 0)?.takeRetainedValue() else { continue }
            let v = IOHIDEventGetFloatValue(ev, kFieldTemperatureLevel)
            if v > 0, v < 130 { out[name] = v }
        }
        return out
    }
}

// MARK: - Зведення

nonisolated enum Sensors {
    static func read() -> Temperatures {
        var t = Temperatures()

        // 1. SMC. Назви ключів різні в різних поколіннях чипа:
        //    M1, M2, M4, M5 — ядра CPU у Tp…/Te…, графіка у Tg…
        //    M3            — частина ядер ще й у Tf0…/Tf4…, графіка також у Tf1…/Tf2…
        //    Intel         — CPU у TC… (TC0D, TC0P, TCAD, TC0c…), графіка у TG… і TCGC
        let all = SMC.readAll()
        for (k, v) in all { t.rawNames["SMC " + k] = v }

        // На частині Mac (M1) кожен датчик є в чотирьох варіантах: …a, …b, …x, …z.
        // Живе значення лише в «a», решта — максимуми, які лишаються високими ще довго
        // після навантаження. У звіті з MacBook Air M1 Tp3a=36° збігається з незалежними
        // датчиками ядер (pACC 35°) і кристала (tdie 38°), а Tp3z=63° суперечить і їм,
        // і холодному корпусу (28°). Тому варіанти b/x/z відкидаємо, якщо є повна четвірка.
        var suffixes: [String: Set<Character>] = [:]
        for k in all.keys where k.count == 4 && "abxz".contains(k.last!) {
            suffixes[String(k.prefix(3)), default: []].insert(k.last!)
        }
        var smc = all
        for (prefix, found) in suffixes where found == Set("abxz") {
            for s in "bxz" { smc.removeValue(forKey: prefix + String(s)) }
        }

        func maxOf(_ prefixes: [String]) -> Double? {
            smc.filter { k, _ in prefixes.contains { k.hasPrefix($0) } }.values.max()
        }

        if let c = maxOf(["Tp", "Te", "Tf0", "Tf4"]) {          // Apple Silicon
            t.cpu = c
            t.cpuLabel = "CPU"
            t.gpu = maxOf(["Tg", "Tf1", "Tf2"])
        } else {                                                 // Intel
            t.cpu = smc.filter { $0.key.hasPrefix("TC") && $0.key != "TCGC" }.values.max()
            if t.cpu != nil { t.cpuLabel = "CPU" }
            t.gpu = smc.filter { $0.key.hasPrefix("TG") || $0.key == "TCGC" }.values.max()
        }
        t.caseTemp = maxOf(["TVS"]) ?? maxOf(["Ts0P", "Ts1P"])   // розрахункова поверхня корпусу; на Intel — датчики під долонями
        t.ssd = maxOf(["TH"])                                     // TH0x — NAND
        t.battery = maxOf(["TB"])                                 // TB0T/TB1T/TB2T

        // 2. IOHID: резерв, якщо SMC нічого не дав (наприклад, у sandbox)
        let hid = HID.readAll()
        for (k, v) in hid { t.rawNames[k] = v }
        if t.cpu == nil {
            var cpu: [Double] = [], die: [Double] = []
            for (name, v) in hid {
                let n = name.lowercased()
                if n.contains("pacc") || n.contains("eacc") || n.contains("cpu") { cpu.append(v) }   // M1: окремі датчики CPU
                else if n.hasPrefix("pmu tdie") { die.append(v) }                                    // M2–M5: датчики кристала без поділу CPU/GPU
            }
            if let c = cpu.max() { t.cpu = c; t.cpuLabel = "CPU" }
            else if let d = die.max() { t.cpu = d; t.cpuLabel = String(localized: "Chip") }
        }
        if t.gpu == nil { t.gpu = hid.filter { $0.key.lowercased().contains("gpu") }.values.max() }
        if t.ssd == nil { t.ssd = hid.filter { let n = $0.key.lowercased(); return n.contains("nand") || n.contains("ssd") }.values.max() }
        return t
    }
}
