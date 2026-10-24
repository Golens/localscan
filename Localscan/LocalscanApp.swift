// Localscan — монітор локальних серверів у рядку меню macOS.
// Copyright (C) 2026 Golens
//
// Вільна програма: ви можете поширювати й змінювати її на умовах
// GNU General Public License версії 3 або, на ваш вибір, будь-якої
// пізнішої версії. Повний текст — у файлі LICENSE.
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

@main
struct LocalscanApp: App {
    @StateObject private var monitor = Monitor()

    var body: some Scene {
        MenuBarExtra {
            PopoverView()
                .environmentObject(monitor)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: monitor.hasTrouble ? "exclamationmark.triangle.fill" : "server.rack")
                Text(menuLabel)
            }
        }
        .menuBarExtraStyle(.window)
    }

    private var menuLabel: String {
        let trouble = monitor.trouble.silent + monitor.trouble.busy
        // «1/6» поруч із трикутником читається як «одна проблема з шести серверів»
        let count = trouble > 0 ? "\(trouble)/\(monitor.servers.count)" : "\(monitor.servers.count)"
        var parts = [count, formatBytes(monitor.totalBytes)]
        if let c = monitor.cpuTemp.average { parts.append("\(Int(c.rounded()))°") }   // згладжене, щоб не скакало
        return parts.joined(separator: " · ")
    }
}
