// Localscan — монітор локальних серверів у рядку меню macOS.
// Copyright (C) 2026 Golens
//
// Вільна програма: ви можете поширювати й змінювати її на умовах
// GNU General Public License версії 3 або, на ваш вибір, будь-якої
// пізнішої версії. Повний текст — у файлі LICENSE.
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Пам'ять усієї системи. Рахуємо так само, як «Моніторинг системи»:
/// зайнято = додатки + пам'ять ядра + стиснуті дані.
nonisolated struct MemoryBreakdown {
    let apps: UInt64
    let wired: UInt64
    let compressed: UInt64
    var used: UInt64 { apps + wired + compressed }
}

nonisolated enum SystemMemory {
    static let physical = ProcessInfo.processInfo.physicalMemory

    static func used() -> UInt64? { breakdown()?.used }

    static func breakdown() -> MemoryBreakdown? {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        var pageSize: vm_size_t = 0
        guard host_page_size(mach_host_self(), &pageSize) == KERN_SUCCESS, pageSize > 0 else { return nil }
        let page = UInt64(pageSize)
        let apps = (UInt64(stats.internal_page_count) - UInt64(stats.purgeable_count)) * page
        let wired = UInt64(stats.wire_count) * page
        let compressed = UInt64(stats.compressor_page_count) * page
        return MemoryBreakdown(apps: apps, wired: wired, compressed: compressed)
    }
}
