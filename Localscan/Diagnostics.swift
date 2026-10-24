// Localscan — монітор локальних серверів у рядку меню macOS.
// Copyright (C) 2026 Golens
//
// Вільна програма: ви можете поширювати й змінювати її на умовах
// GNU General Public License версії 3 або, на ваш вибір, будь-якої
// пізнішої версії. Повний текст — у файлі LICENSE.
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import AppKit

/// Звіт про залізо і температурні датчики. Потрібен, щоб зібрати назви датчиків
/// із Mac інших поколінь: на кожному чипі вони називаються по-різному.
/// У звіт не потрапляє нічого про проєкти користувача — лише модель Mac і датчики.
nonisolated enum Diagnostics {

    static func text(_ t: Temperatures) -> String {
        let info = Bundle.main.infoDictionary ?? [:]
        // збірка в дужках: під час бета-тесту версія лишається 1.0, а номер збірки росте
        let version = "\(info["CFBundleShortVersionString"] as? String ?? "?") (\(info["CFBundleVersion"] as? String ?? "?"))"
        let none = String(localized: "not found")
        func row(_ label: String, _ value: Double?) -> String {
            label.padding(toLength: max(label.count + 1, 11), withPad: " ", startingAt: 0)
                + (value.map { String(format: "%.1f°", locale: .current, $0) } ?? none)
        }
        var lines = [
            String(localized: "Localscan \(version) — sensor report"),
            systemSummary(),
            Date().formatted(date: .abbreviated, time: .standard),
            "",
            String(localized: "What the app found:"),
            row("  CPU:", t.cpu),
            row("  GPU:", t.gpu),
            row("  " + String(localized: "Case") + ":", t.caseTemp),
            row("  SSD:", t.ssd),
            row("  " + String(localized: "Battery") + ":", t.battery),
            "",
            String(localized: "All sensors (\(t.rawNames.count)):"),
        ]
        lines += t.rawNames.sorted { $0.key < $1.key }.map { String(format: "  %@: %.1f", $0.key, $0.value) }
        return lines.joined(separator: "\n")
    }

    /// Поруч зі станом додатка, щоб файл завжди був під рукою і без запиту доступу до тек
    static var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Localscan", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(String(localized: "Sensor report") + ".txt")
    }

    @discardableResult
    static func write(_ t: Temperatures) -> URL {
        let url = fileURL
        try? text(t).data(using: .utf8)?.write(to: url, options: .atomic)
        return url
    }
}
