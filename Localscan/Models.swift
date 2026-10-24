// Localscan — монітор локальних серверів у рядку меню macOS.
// Copyright (C) 2026 Golens
//
// Вільна програма: ви можете поширювати й змінювати її на умовах
// GNU General Public License версії 3 або, на ваш вибір, будь-якої
// пізнішої версії. Повний текст — у файлі LICENSE.
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Один запущений localhost (процес, який слухає порт)
nonisolated struct ServerProcess: Identifiable, Hashable {
    let pid: Int32
    let port: Int
    let command: String          // коротка назва: node, Python, com.docker...
    let fullCommand: String      // повна команда запуску
    let cwd: String              // папка проєкту
    let startedAt: Date?
    let rssBytes: UInt64         // пам'ять самого процесу
    let cpuPercent: Double
    let children: [ChildProcess]
    let dockerContainer: String?

    var id: String { "\(pid):\(port)" }

    /// Пам'ять разом із дочірніми процесами
    var totalBytes: UInt64 { rssBytes + children.reduce(0) { $0 + $1.rssBytes } }
    var totalCPU: Double { cpuPercent + children.reduce(0) { $0 + $1.cpuPercent } }

    /// Людська назва: Next.js, Vite, FastAPI...
    var framework: String {
        let c = fullCommand.lowercased()
        if let d = dockerContainer { return "Docker · \(d)" }
        if c.contains("next") { return "Next.js" }
        if c.contains("vite") { return "Vite" }
        if c.contains("nuxt") { return "Nuxt" }
        if c.contains("uvicorn") || c.contains("fastapi") { return "FastAPI" }
        if c.contains("streamlit") { return "Streamlit" }
        if c.contains("flask") { return "Flask" }
        if c.contains("django") || c.contains("manage.py") { return "Django" }
        if c.contains("express") { return "Express" }
        if c.contains("ollama") { return "Ollama" }
        if c.contains("postgres") { return "PostgreSQL" }
        if c.contains("redis") { return "Redis" }
        return command
    }

    var shortCwd: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return cwd.hasPrefix(home) ? "~" + cwd.dropFirst(home.count) : cwd
    }

    /// Чи можна слати цьому серверу HTTP-запит під час перевірки.
    /// Тільки впізнані веб-фреймворки: базі даних такий запит піде в лог як помилка.
    var isWeb: Bool {
        ["Next.js", "Vite", "Nuxt", "FastAPI", "Streamlit", "Flask", "Django", "Express"].contains(framework)
    }
}

nonisolated struct ChildProcess: Identifiable, Hashable {
    let pid: Int32
    let name: String
    let rssBytes: UInt64
    let cpuPercent: Double
    var id: Int32 { pid }
}

/// Проєкт, який додаток запам'ятав (для вкладки «Зупинені»)
nonisolated struct SavedProject: Codable, Identifiable, Hashable {
    var id: String { cwd + "|" + launchCommand }
    var cwd: String
    var launchCommand: String
    var framework: String
    var lastPort: Int
    var lastSeen: Date
    var stoppedAt: Date?
    var peakBytes: UInt64

    var shortCwd: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return cwd.hasPrefix(home) ? "~" + cwd.dropFirst(home.count) : cwd
    }
}

/// Одна точка на графіку пам'яті
nonisolated struct MemorySample: Codable {
    let at: Date
    let totalBytes: UInt64
    var systemBytes: UInt64?     // порожнє в точках, збережених до появи системного графіка
}

/// Середнє й пік за останні секунди. Ядра Apple Silicon гріються й холонуть
/// на десятки градусів за секунди, тож миттєвий замір раз на 3 с скаче 50 → 90 → 60,
/// хоча нічого не зламано. Для показу беремо середнє, пік лишаємо для підказки.
nonisolated struct Smoother {
    var window: TimeInterval = 15
    private var points: [(at: Date, value: Double)] = []

    private(set) var average: Double?
    private(set) var peak: Double?

    mutating func add(_ value: Double?, at now: Date = Date()) {
        if let value { points.append((now, value)) }
        points.removeAll { now.timeIntervalSince($0.at) > window }
        average = points.isEmpty ? nil : points.map(\.value).reduce(0, +) / Double(points.count)
        peak = points.map(\.value).max()
    }
}

nonisolated struct Temperatures {
    var cpu: Double?              // найгарячіше ядро CPU
    var cpuLabel = "CPU"          // "Чип", якщо є лише датчики кристала без поділу CPU/GPU (резервний шлях через IOHID)
    var gpu: Double?              // найгарячіший датчик GPU
    var caseTemp: Double?         // розрахункова температура поверхні корпусу (SMC TVS0/TVS1): те, що відчуває рука
    var ssd: Double?
    var battery: Double?
    var rawNames: [String: Double] = [:]   // усі датчики обох джерел — для кнопки «датчики?»
}

/// Браузер, запущений для автоматичних перевірок (Puppeteer, Playwright, агенти):
/// відкриває порт налагодження на кілька секунд і не є сервером розробки.
/// Без цього фільтра в одному з проєктів за хвилину з'являлось і зникало до шести таких «серверів»,
/// і вони витіснили з історії справжні проєкти.
nonisolated func isAutomationBrowser(_ command: String) -> Bool {
    command.contains("--headless") || command.contains("--remote-debugging-port") || command.contains("--remote-debugging-pipe")
}

/// Модель Mac, чип і версія macOS — для звіту про датчики з іншого комп'ютера
nonisolated func systemSummary() -> String {
    func value(_ name: String) -> String {
        var size = 0
        sysctlbyname(name, nil, &size, nil, 0)
        guard size > 0 else { return "?" }
        var buf = [CChar](repeating: 0, count: size)
        sysctlbyname(name, &buf, &size, nil, 0)
        let bytes = buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }
    let os = ProcessInfo.processInfo.operatingSystemVersion
    return "\(value("hw.model")) · \(value("machdep.cpu.brand_string")) · macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
}

nonisolated func formatBytes(_ b: UInt64) -> String {
    let mb = Double(b) / 1_048_576
    // locale: десятковий роздільник за мовою системи (кома в українській, крапка в англійській)
    if mb >= 1000 { return String(format: "%.2f %@", locale: .current, mb / 1024, String(localized: "GB")) }
    return String(format: "%.0f %@", locale: .current, mb, String(localized: "MB"))
}

nonisolated func formatUptime(since date: Date?) -> String {
    guard let date else { return "" }
    let s = Int(Date().timeIntervalSince(date))
    let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
    if d > 0 { return String(localized: "uptime.days", defaultValue: "\(d)d \(h)h") }
    if h > 0 { return String(localized: "uptime.hours", defaultValue: "\(h)h \(m)m") }
    return String(localized: "uptime.minutes", defaultValue: "\(m)m")
}
