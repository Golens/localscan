// Localscan — монітор локальних серверів у рядку меню macOS.
// Copyright (C) 2026 Golens
//
// Вільна програма: ви можете поширювати й змінювати її на умовах
// GNU General Public License версії 3 або, на ваш вибір, будь-якої
// пізнішої версії. Повний текст — у файлі LICENSE.
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Запускає системну команду і повертає її текстовий вивід
@discardableResult
nonisolated func shell(_ args: [String], cwd: String? = nil, env: [String: String]? = nil) -> String {
    let p = Process()
    // абсолютний шлях запускаємо напряму, без зайвого проміжного /usr/bin/env
    if args[0].hasPrefix("/") {
        p.executableURL = URL(fileURLWithPath: args[0])
        p.arguments = Array(args.dropFirst())
    } else {
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = args
    }
    if let cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
    // GUI-додаток має короткий PATH; додаємо шляхи Homebrew/Docker, щоб знайти docker
    var environment = ProcessInfo.processInfo.environment
    environment["PATH"] = (environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin") + ":/usr/local/bin:/opt/homebrew/bin"
    if let env { environment.merge(env) { $1 } }
    p.environment = environment
    let out = Pipe()
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    // waitUntilExit() чекає опитуванням і додає ~80 мс на кожен виклик; семафор спрацьовує миттєво
    let done = DispatchSemaphore(value: 0)
    p.terminationHandler = { _ in done.signal() }
    do { try p.run() } catch { return "" }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    done.wait()
    return String(decoding: data, as: UTF8.self)
}

private struct PSRow { let pid: Int32; let ppid: Int32; let rss: UInt64; let cpu: Double; let comm: String }

nonisolated enum ProcessScanner {

    /// Головна функція: знаходить усі процеси, що слухають TCP-порти
    static func scan() -> [ServerProcess] {
        // 1. Хто слухає порти. lsof без sudo показує тільки процеси поточного користувача — це нам і треба
        let lsof = shell(["/usr/sbin/lsof", "-nP", "-iTCP", "-sTCP:LISTEN", "-F", "pcn"])
        var listeners: [(pid: Int32, cmd: String, port: Int)] = []
        var pid: Int32 = 0, cmd = ""
        for line in lsof.split(separator: "\n") {
            guard let tag = line.first else { continue }
            let value = String(line.dropFirst())
            switch tag {
            case "p": pid = Int32(value) ?? 0
            case "c": cmd = value
            case "n":
                if let portStr = value.split(separator: ":").last, let port = Int(portStr) {
                    listeners.append((pid, cmd, port))
                }
            default: break
            }
        }
        // один процес може слухати один порт і на IPv4, і на IPv6 — прибираємо дублі
        var seen = Set<String>()
        listeners = listeners.filter { seen.insert("\($0.pid):\($0.port)").inserted }
        if listeners.isEmpty { return [] }

        // 2. Одним викликом беремо дані всіх процесів
        let ps = shell(["/bin/ps", "-axo", "pid=,ppid=,rss=,%cpu=,comm="])
        var rows: [Int32: PSRow] = [:]
        var childrenOf: [Int32: [Int32]] = [:]
        for line in ps.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: true)
            guard parts.count >= 5, let p = Int32(parts[0]), let pp = Int32(parts[1]),
                  let rss = UInt64(parts[2]), let cpu = Double(parts[3]) else { continue }
            let name = String(parts[4]).split(separator: "/").last.map(String.init) ?? String(parts[4])
            rows[p] = PSRow(pid: p, ppid: pp, rss: rss * 1024, cpu: cpu, comm: name)
            childrenOf[pp, default: []].append(p)
        }

        let docker = dockerPorts()

        // 3. Одним викликом lsof і одним ps беремо папку, повну команду і час старту для всіх слухачів
        let pids = listeners.map { String($0.pid) }.joined(separator: ",")
        var cwdOf: [Int32: String] = [:]
        var current: Int32 = 0
        for line in shell(["/usr/sbin/lsof", "-a", "-p", pids, "-d", "cwd", "-Fn"]).split(separator: "\n") {
            if line.hasPrefix("p") { current = Int32(line.dropFirst()) ?? 0 }
            else if line.hasPrefix("n") { cwdOf[current] = String(line.dropFirst()) }
        }
        var argsOf: [Int32: String] = [:], startOf: [Int32: Date] = [:]
        for line in shell(["/bin/ps", "-o", "pid=,lstart=,args=", "-p", pids]).split(separator: "\n") {
            // "14350 Sun Sep 20 15:36:44 2026 node /path/vite --port 5173"
            let parts = line.split(separator: " ", maxSplits: 6, omittingEmptySubsequences: true)
            guard parts.count >= 6, let p = Int32(parts[0]) else { continue }
            startOf[p] = parseStart(parts[1...5].joined(separator: " "))
            if parts.count == 7 { argsOf[p] = String(parts[6]).trimmingCharacters(in: .whitespaces) }
        }

        // 4. Збираємо картку для кожного
        return listeners.compactMap { l in
            guard let row = rows[l.pid] else { return nil }
            let cwd = cwdOf[l.pid] ?? ""
            let full = argsOf[l.pid] ?? row.comm
            let started = startOf[l.pid]

            var kids: [ChildProcess] = []
            var queue = childrenOf[l.pid] ?? []
            while let k = queue.popLast(), let r = rows[k] {
                kids.append(ChildProcess(pid: k, name: r.comm, rssBytes: r.rss, cpuPercent: r.cpu))
                queue.append(contentsOf: childrenOf[k] ?? [])
            }

            return ServerProcess(pid: l.pid, port: l.port, command: row.comm, fullCommand: full,
                                 cwd: cwd, startedAt: started, rssBytes: row.rss, cpuPercent: row.cpu,
                                 children: kids, dockerContainer: docker[l.port])
        }
        .filter { !$0.isSystemNoise && !isAutomationBrowser($0.fullCommand) }
        .sorted { $0.port < $1.port }
    }

    /// Порт → назва Docker-контейнера (якщо Docker встановлений; інакше порожньо)
    /// Де лежить docker, шукаємо один раз; якщо його немає — не запускаємо нічого
    private static let dockerPath: String? =
        ["/usr/local/bin/docker", "/opt/homebrew/bin/docker", "/usr/bin/docker"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }

    /// Відповідь Docker кешується на 30 с: смикати демон кожні 3 с нема сенсу
    nonisolated(unsafe) private static var dockerCache: (at: Date, ports: [Int: String]) = (.distantPast, [:])

    private static func dockerPorts() -> [Int: String] {
        guard let dockerPath else { return [:] }
        if Date().timeIntervalSince(dockerCache.at) < 30 { return dockerCache.ports }
        let out = shell([dockerPath, "ps", "--format", "{{.Names}}\t{{.Ports}}"])
        var map: [Int: String] = [:]
        for line in out.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1)
            guard parts.count == 2 else { continue }
            // приклад Ports: 0.0.0.0:5432->5432/tcp
            for m in parts[1].split(separator: ",") {
                if let host = m.split(separator: "-").first, let p = host.split(separator: ":").last, let port = Int(p) {
                    map[port] = String(parts[0])
                }
            }
        }
        dockerCache = (Date(), map)
        return map
    }

    private static func parseStart(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        return f.date(from: s.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "  ", with: " "))
    }

    /// Чи порт вільний
    /// Без запуску lsof: спроба з'єднання відповідає миттєво
    static func isPortFree(_ port: Int) -> Bool {
        Prober.probe(port: port, http: false) == .unreachable
    }

    static func nextFreePort(after port: Int) -> Int {
        var p = port + 1
        while !isPortFree(p) && p < port + 50 { p += 1 }
        return p
    }
}

nonisolated private extension ServerProcess {
    /// Системні слухачі, які не є проєктами (можна розширити)
    var isSystemNoise: Bool {
        let noise = ["rapportd", "ControlCenter", "sharingd", "AirPlayXPCHelper", "Adobe", "Creative Cloud"]
        return noise.contains { command.localizedCaseInsensitiveContains($0) }
    }
}
