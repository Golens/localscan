// Localscan — монітор локальних серверів у рядку меню macOS.
// Copyright (C) 2026 Golens
//
// Вільна програма: ви можете поширювати й змінювати її на умовах
// GNU General Public License версії 3 або, на ваш вибір, будь-якої
// пізнішої версії. Повний текст — у файлі LICENSE.
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Зберігає історію проєктів і графік пам'яті у файлі
/// ~/Library/Application Support/Localscan/state.json
enum Store {
    struct State: Codable {
        var projects: [SavedProject] = []
        var samples: [MemorySample] = []
    }

    private static let url: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = support.appendingPathComponent("Localscan", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("state.json")

        // Переносимо історію з часів, коли додаток називався LocalhostMonitor
        let old = support.appendingPathComponent("LocalhostMonitor/state.json")
        if !FileManager.default.fileExists(atPath: file.path),
           FileManager.default.fileExists(atPath: old.path) {
            try? FileManager.default.copyItem(at: old, to: file)
        }
        return file
    }()

    static func load() -> State {
        guard let data = try? Data(contentsOf: url),
              let s = try? JSONDecoder().decode(State.self, from: data) else { return State() }
        return s
    }

    static func save(_ s: State) {
        if let data = try? JSONEncoder().encode(s) { try? data.write(to: url, options: .atomic) }
    }
}
