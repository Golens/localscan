// Localscan — монітор локальних серверів у рядку меню macOS.
// Copyright (C) 2026 Golens
//
// Вільна програма: ви можете поширювати й змінювати її на умовах
// GNU General Public License версії 3 або, на ваш вибір, будь-якої
// пізнішої версії. Повний текст — у файлі LICENSE.
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Darwin

/// Чим закінчилася перевірка сервера
nonisolated enum ProbeResult: Equatable {
    case responding      // відповів
    case silent          // з'єднання прийняв, але відповіді немає — схоже на зависання
    case unreachable     // порт не приймає з'єднання
}

/// Стукає в локальний порт, щоб зрозуміти, чи сервер живий.
/// Завислий процес ззовні виглядає здоровим: порт слухається, пам'ять на місці,
/// процесор нуль. Відрізнити можна лише спробувавши поговорити з ним.
nonisolated enum Prober {

    /// http = true лише для впізнаних веб-серверів. Базі даних не можна слати HTTP:
    /// вона запише помилку в свій лог. Для них перевіряємо тільки, чи приймається з'єднання.
    static func probe(port: Int, http: Bool, timeout: TimeInterval = 2) -> ProbeResult {
        // Багато серверів слухають лише IPv6 ([::1]), тому пробуємо обидві адреси,
        // інакше здоровий сервер виглядав би як «порт не приймає з'єднання».
        for ipv6 in [false, true] {
            guard let fd = openConnection(port: port, ipv6: ipv6) else { continue }
            defer { close(fd) }
            return http ? ask(fd, timeout: timeout) : .responding
        }
        return .unreachable
    }

    /// Повертає відкритий сокет або nil, якщо з'єднання не встановилось за секунду
    private static func openConnection(port: Int, ipv6: Bool) -> Int32? {
        let fd = socket(ipv6 ? AF_INET6 : AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }

        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        var started: Int32 = -1
        if ipv6 {
            var addr = sockaddr_in6()
            addr.sin6_family = sa_family_t(AF_INET6)
            addr.sin6_port = UInt16(port).bigEndian
            inet_pton(AF_INET6, "::1", &addr.sin6_addr)
            started = withUnsafePointer(to: &addr) { raw in
                raw.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
                }
            }
        } else {
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = UInt16(port).bigEndian
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")
            started = withUnsafePointer(to: &addr) { raw in
                raw.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }

        if started != 0 {
            guard errno == EINPROGRESS else { close(fd); return nil }
            var waiting = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            guard poll(&waiting, 1, 1000) > 0 else { close(fd); return nil }
            var socketError: Int32 = 0
            var size = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &size)
            guard socketError == 0 else { close(fd); return nil }
        }
        _ = fcntl(fd, F_SETFL, flags & ~O_NONBLOCK)
        return fd
    }

    /// Ставить серверу найлегший можливий запит і чекає бодай якоїсь відповіді
    private static func ask(_ fd: Int32, timeout: TimeInterval) -> ProbeResult {
        var limit = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))

        // HEAD, а не GET: сервер не готуватиме тіло відповіді
        let request = "HEAD / HTTP/1.0\r\nHost: localhost\r\nUser-Agent: Localscan\r\n\r\n"
        _ = request.withCString { send(fd, $0, strlen($0), 0) }

        var buffer = [UInt8](repeating: 0, count: 64)
        let received = recv(fd, &buffer, buffer.count, 0)
        return received > 0 ? .responding : .silent
    }
}
