// Localscan — монітор локальних серверів у рядку меню macOS.
// Copyright (C) 2026 Golens
//
// Вільна програма: ви можете поширювати й змінювати її на умовах
// GNU General Public License версії 3 або, на ваш вибір, будь-якої
// пізнішої версії. Повний текст — у файлі LICENSE.
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Combine
import ServiceManagement
import AppKit

/// «Мозок» додатка: раз на кілька секунд сканує систему і оновлює інтерфейс
@MainActor
final class Monitor: ObservableObject {
    @Published var servers: [ServerProcess] = []
    @Published var temps = Temperatures()
    @Published var samples: [MemorySample] = []          // графік за останню годину
    @Published var projects: [SavedProject] = []         // усе, що додаток бачив
    @Published var sessionPeak: [String: UInt64] = [:]   // пік пам'яті проєкту за сесію (ключ: cwd|команда)
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published var lastError: String?
    @Published var systemUsed: UInt64?          // зайнято пам'яті в усій системі
    @Published var cpuTemp = Smoother()         // згладжена температура процесора для показу
    @Published var gpuTemp = Smoother()
    @Published var health: [String: ProbeResult] = [:]   // результат останньої перевірки сервера
    @Published var checking: Set<String> = []            // перевірка саме зараз триває
    @Published var busySince: [String: Date] = [:]       // відколи сервер тримає процесор
    @Published var stubborn: String?                     // не зупинився м'якою командою
    @Published var stopping: Set<String> = []            // команду зупинки надіслано, чекаємо завершення
    private var pendingRestart: Set<String> = []
    private var lastProbe: [String: Date] = [:]
    private var probeTimer: Timer?

    /// Скільки процесора вважаємо підозрілим і як довго це має тривати
    private let heavyCPU = 85.0
    private let heavyFor: TimeInterval = 120
    let physicalMemory = SystemMemory.physical

    /// Логи проєктів, запущених через додаток
    @Published var logs: [String: [String]] = [:]
    private var running: [String: Process] = [:]

    private var timer: Timer?
    private var state = Store.load()

    init() {
        projects = Monitor.cleaned(state.projects)
        samples = state.samples.filter { $0.at > Date().addingTimeInterval(-3600) }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        timer?.tolerance = 0.5          // дозволяє системі групувати пробудження — менше енергії
        // веб-сервери перевіряємо самі, решту — лише на вимогу
        probeTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.probeWebServers() }
        }
        probeTimer?.tolerance = 5
        // стан на диск пишемо рідко, але перед виходом — обов'язково
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.persist() }
        }
    }

    var totalBytes: UInt64 { servers.reduce(0) { $0 + $1.totalBytes } }
    var totalCPU: Double { servers.reduce(0) { $0 + $1.totalCPU } }
    var peakSample: MemorySample? { samples.max { $0.totalBytes < $1.totalBytes } }

    var stoppedProjects: [SavedProject] {
        let live = Set(servers.map { $0.cwd + "|" + $0.fullCommand })
        return projects.filter { !live.contains($0.id) }.sorted { $0.lastSeen > $1.lastSeen }
    }

    private var refreshing = false
    private var refreshStarted: Date?
    private var reportWrittenAt: Date?
    private var refreshCount = 0
    private var lastSave = Date()

    func refresh() {
        // попереднє сканування ще триває — не накладаємо друге; але якщо воно
        // висить понад 30 с (наприклад, lsof застряг), не блокуємось назавжди
        if refreshing, let started = refreshStarted, Date().timeIntervalSince(started) < 30 { return }
        refreshing = true
        refreshStarted = Date()
        Task.detached(priority: .utility) {
            let found = ProcessScanner.scan()
            let t = Sensors.read()
            let system = SystemMemory.used()
            await MainActor.run {
                self.apply(found, t, system)
                self.refreshing = false
            }
        }
    }

    private func apply(_ found: [ServerProcess], _ t: Temperatures, _ system: UInt64?) {
        servers = found
        temps = t
        systemUsed = system
        cpuTemp.add(t.cpu)
        gpuTemp.add(t.gpu)

        // Звіт про датчики оновлюється сам, щоб його завжди можна було надіслати
        if reportWrittenAt.map({ Date().timeIntervalSince($0) > 300 }) ?? true {
            reportWrittenAt = Date()
            let snapshot = t
            Task.detached(priority: .background) { Diagnostics.write(snapshot) }
        }

        // графік
        samples.append(MemorySample(at: Date(), totalBytes: totalBytes, systemBytes: system))
        samples.removeAll { $0.at < Date().addingTimeInterval(-3600) }

        // пам'ять про проєкти + пік
        let now = Date()
        let liveKeys = Set(found.filter { !$0.cwd.isEmpty }.map { $0.cwd + "|" + $0.fullCommand })
        for key in liveKeys where firstSeen[key] == nil { firstSeen[key] = now }
        firstSeen = firstSeen.filter { liveKeys.contains($0.key) }
        for s in found where !s.cwd.isEmpty {
            let key = s.cwd + "|" + s.fullCommand
            sessionPeak[key] = max(sessionPeak[key] ?? 0, s.totalBytes)
            if let i = projects.firstIndex(where: { $0.id == key }) {
                projects[i].lastSeen = now
                projects[i].lastPort = s.port
                projects[i].stoppedAt = nil
                projects[i].peakBytes = max(projects[i].peakBytes, s.totalBytes)
            } else if now.timeIntervalSince(firstSeen[key] ?? now) >= minLifetime {
                projects.append(SavedProject(cwd: s.cwd, launchCommand: s.fullCommand, framework: s.framework,
                                             lastPort: s.port, lastSeen: now, stoppedAt: nil, peakBytes: s.totalBytes))
            }
        }
        // хто довго тримає процесор
        for s in found {
            if s.totalCPU >= heavyCPU { if busySince[s.id] == nil { busySince[s.id] = now } }
            else { busySince[s.id] = nil }
        }
        let liveIDs = Set(found.map(\.id))
        busySince = busySince.filter { liveIDs.contains($0.key) }
        health = health.filter { liveIDs.contains($0.key) }
        lastProbe = lastProbe.filter { liveIDs.contains($0.key) }
        if let id = stubborn, !liveIDs.contains(id) { stubborn = nil }
        stopping = stopping.filter { liveIDs.contains($0) }

        let live = Set(found.map { $0.cwd + "|" + $0.fullCommand })
        for i in projects.indices where !live.contains(projects[i].id) && projects[i].stoppedAt == nil {
            projects[i].stoppedAt = now
        }
        projects = Array(projects.sorted { $0.lastSeen > $1.lastSeen }.prefix(30))

        // На диск — лише коли змінився склад проєктів або раз на хвилину.
        // Раніше 85 КБ переписувались кожні 3 с: ~100 МБ на годину даремних записів.
        refreshCount += 1
        let signature = projects.map { "\($0.id)|\($0.stoppedAt == nil)" }
        if signature != lastSignature || Date().timeIntervalSince(lastSave) > 60 {
            lastSignature = signature
            persist()
        }
    }

    private var lastSignature: [String] = []

    /// Відколи кожен живий проєкт видно поспіль. У історію потрапляє лише те,
    /// що прожило хоча б три сканування: одноразові тестові сервери туди не пишуться.
    private var firstSeen: [String: Date] = [:]
    private let minLifetime: TimeInterval = 5

    /// Прибирає з історії те, що не є проєктом: браузери для автоматизації
    /// і проєкти, чиєї папки вже немає, — їх однаково не запустити
    private static func cleaned(_ list: [SavedProject]) -> [SavedProject] {
        list.filter { !isAutomationBrowser($0.launchCommand) && FileManager.default.fileExists(atPath: $0.cwd) }
    }

    private func persist() {
        state.projects = projects
        state.samples = samples
        Store.save(state)
        lastSave = Date()
    }

    // MARK: стан здоров'я

    /// Сервер тримає процесор довше за поріг
    func isBusy(_ s: ServerProcess) -> Bool {
        guard let since = busySince[s.id] else { return false }
        return Date().timeIntervalSince(since) >= heavyFor
    }

    func busyFor(_ s: ServerProcess) -> String {
        formatUptime(since: busySince[s.id])
    }

    var trouble: (silent: Int, busy: Int) {
        var silent = 0, busy = 0
        for s in servers {
            if health[s.id] == .silent || health[s.id] == .unreachable { silent += 1 }
            else if isBusy(s) { busy += 1 }
        }
        return (silent, busy)
    }

    var hasTrouble: Bool { trouble.silent > 0 || trouble.busy > 0 }

    /// Перевірка на вимогу — працює для будь-якого сервера
    func check(_ s: ServerProcess) {
        guard !checking.contains(s.id) else { return }
        checking.insert(s.id)
        let id = s.id, port = s.port, http = s.isWeb
        Task.detached(priority: .utility) {
            let result = Prober.probe(port: port, http: http)
            await MainActor.run {
                self.health[id] = result
                self.lastProbe[id] = Date()
                self.checking.remove(id)
            }
        }
    }

    /// Автоматична перевірка лише веб-серверів
    private func probeWebServers() {
        let due = servers.filter { $0.isWeb && Date().timeIntervalSince(lastProbe[$0.id] ?? .distantPast) > 20 }
            .map { (id: $0.id, port: $0.port) }
        guard !due.isEmpty else { return }
        Task.detached(priority: .utility) {
            let results: [String: ProbeResult] = due.reduce(into: [:]) { found, item in
                found[item.id] = Prober.probe(port: item.port, http: true)
            }
            await MainActor.run {
                let now = Date()
                for (id, result) in results {
                    self.health[id] = result
                    self.lastProbe[id] = now
                }
            }
        }
    }

    // MARK: дії

    /// М'яка зупинка. Якщо процес завис, він її проігнорує — тоді пропонуємо примусову.
    func stop(_ s: ServerProcess, thenRestart: Bool = false) {
        for c in s.children { kill(c.pid, SIGTERM) }
        kill(s.pid, SIGTERM)
        if thenRestart { pendingRestart.insert(s.id) }
        stopping.insert(s.id)
        let pid = s.pid, id = s.id
        Task { @MainActor [weak self] in
            // кожні пів секунди дивимось, чи процес уже завершився, —
            // рядок зникає одразу, а не чекає наступного сканування
            for _ in 0..<6 {
                try? await Task.sleep(nanoseconds: 500_000_000)
                if kill(pid, 0) != 0 { break }
            }
            guard let self else { return }
            self.stopping.remove(id)
            if kill(pid, 0) == 0 {
                self.stubborn = id               // за 3 с не завершився — пропонуємо примусову
            } else {
                if self.stubborn == id { self.stubborn = nil }
                self.servers.removeAll { $0.id == id }
                if self.pendingRestart.remove(id) != nil { self.relaunch(s) }
            }
            self.refresh()
        }
    }

    func forceStop(_ s: ServerProcess) {
        for c in s.children { kill(c.pid, SIGKILL) }
        kill(s.pid, SIGKILL)
        stubborn = nil
        stopping.insert(s.id)
        let pid = s.pid, id = s.id
        Task { @MainActor [weak self] in
            for _ in 0..<4 {
                try? await Task.sleep(nanoseconds: 250_000_000)
                if kill(pid, 0) != 0 { break }
            }
            guard let self else { return }
            self.stopping.remove(id)
            if kill(pid, 0) != 0 { self.servers.removeAll { $0.id == id } }
            if self.pendingRestart.remove(id) != nil { self.relaunch(s) }
            self.refresh()
        }
    }

    func cancelForceStop(_ s: ServerProcess) {
        stubborn = nil
        pendingRestart.remove(s.id)
    }

    func restart(_ s: ServerProcess) { stop(s, thenRestart: true) }

    /// Піднімає той самий сервер тією ж командою в тій же папці
    private func relaunch(_ s: ServerProcess) {
        guard !s.cwd.isEmpty, !s.fullCommand.isEmpty else { return }
        launch(SavedProject(cwd: s.cwd, launchCommand: s.fullCommand, framework: s.framework,
                            lastPort: s.port, lastSeen: Date(), stoppedAt: nil, peakBytes: s.totalBytes))
    }

    var canRestart: (ServerProcess) -> Bool { { !$0.cwd.isEmpty && !$0.fullCommand.isEmpty } }

    func openInBrowser(_ s: ServerProcess) {
        if let url = URL(string: "http://localhost:\(s.port)") { NSWorkspace.shared.open(url) }
    }

    func revealInFinder(_ path: String) {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
    }

    /// Запуск збереженого проєкту. altPort — якщо треба інший порт (передаємо через змінну PORT)
    func launch(_ p: SavedProject, altPort: Int? = nil) {
        // команда з ps містить повний шлях до node/python — це нормально, zsh її виконає
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        proc.arguments = ["-lc", p.launchCommand]
        proc.currentDirectoryURL = URL(fileURLWithPath: p.cwd)
        var env = ProcessInfo.processInfo.environment
        if let altPort { env["PORT"] = String(altPort) }
        proc.environment = env

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        let key = p.id
        logs[key] = []
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            if data.isEmpty { h.readabilityHandler = nil; return }   // EOF: процес завершився
            let text = String(decoding: data, as: UTF8.self)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.logs[key, default: []].append(contentsOf: text.split(separator: "\n").map(String.init))
                if let n = self.logs[key]?.count, n > 200 { self.logs[key]?.removeFirst(n - 200) }
            }
        }
        proc.terminationHandler = { [weak self] _ in
            Task { @MainActor [weak self] in self?.running[key] = nil }
        }
        do {
            try proc.run()
            running[key] = proc
            lastError = nil
        } catch {
            lastError = String(localized: "Could not start: \(error.localizedDescription)")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.refresh() }
    }

    /// Хто тримає порт (для повідомлення про конфлікт)
    func holder(of port: Int) -> ServerProcess? { servers.first { $0.port == port } }

    func forget(_ p: SavedProject) {
        projects.removeAll { $0.id == p.id }
        state.projects = projects
        Store.save(state)
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            launchAtLogin = SMAppService.mainApp.status == .enabled
        } catch {
            lastError = String(localized: "Launch at login: \(error.localizedDescription)")
        }
    }
}
