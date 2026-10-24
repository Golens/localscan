// Localscan — монітор локальних серверів у рядку меню macOS.
// Copyright (C) 2026 Golens
//
// Вільна програма: ви можете поширювати й змінювати її на умовах
// GNU General Public License версії 3 або, на ваш вибір, будь-якої
// пізнішої версії. Повний текст — у файлі LICENSE.
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Darwin

/// Один додаток (або окремий процес) і скільки пам'яті він тримає
nonisolated struct MemoryHog: Identifiable, Equatable {
    let name: String
    let bytes: UInt64       // фізичний слід усіх його процесів, разом зі стиснутими сторінками
    let processes: Int
    var id: String { name }
}

/// Хто займає пам'ять усієї системи. Читає слід кожного процесу через libproc —
/// це те саме число, що показує «Моніторинг системи» у стовпчику «Пам'ять».
/// Працює без прав адміністратора для процесів поточного користувача;
/// системні процеси інших користувачів просто пропускаються.
nonisolated enum MemoryHogs {

    /// Додатки, чий сумарний слід не менший за поріг, від найбільшого
    static func top(minBytes: UInt64 = 1 << 30) -> [MemoryHog] {
        var bytesByApp: [String: UInt64] = [:]
        var countByApp: [String: Int] = [:]

        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 32)
        let got = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard got > 0 else { return [] }

        for pid in pids.prefix(Int(got)) where pid > 0 {
            var usage = rusage_info_v4()
            let ok = withUnsafeMutablePointer(to: &usage) { p in
                p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
            }
            guard ok == 0, usage.ri_phys_footprint > 0 else { continue }

            var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
            guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { continue }
            let path = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            let name = appName(for: path, pid: pid)
            bytesByApp[name, default: 0] += usage.ri_phys_footprint
            countByApp[name, default: 0] += 1
        }

        return bytesByApp
            .filter { $0.value >= minBytes }
            .map { MemoryHog(name: $0.key, bytes: $0.value, processes: countByApp[$0.key] ?? 1) }
            .sorted { $0.bytes > $1.bytes }
    }

    /// Назва додатка за шляхом до виконуваного файлу: перший компонент «.app» —
    /// так усі помічники Chrome лягають в один рядок «Google Chrome»
    private static func appName(for path: String, pid: pid_t) -> String {
        let parts = path.split(separator: "/")
        if let app = parts.first(where: { $0.hasSuffix(".app") }) {
            return String(app.dropLast(4))
        }
        let executable = String(parts.last ?? "")
        if executable == "com.apple.Virtualization.VirtualMachine" {
            return vmOwner(pid: pid)
        }
        return executable
    }

    /// Віртуальна машина у системі безіменна; хто її запустив, видно
    /// з файлів, які вона тримає відкритими. Відповідь кешується по pid.
    nonisolated(unsafe) private static var vmOwners: [pid_t: String] = [:]

    private static func vmOwner(pid: pid_t) -> String {
        if let cached = vmOwners[pid] { return cached }
        let generic = String(localized: "Virtual machine")
        var owner = generic
        let files = shell(["/usr/sbin/lsof", "-p", "\(pid)", "-Fn"])
        for line in files.split(separator: "\n") where line.hasPrefix("n") {
            if let range = line.range(of: "/Application Support/") {
                let rest = line[range.upperBound...]
                if let name = rest.split(separator: "/").first, !name.isEmpty {
                    owner = String(localized: "Virtual machine of \(String(name))")
                    break
                }
            }
        }
        vmOwners[pid] = owner
        return owner
    }
}
