// Localscan — монітор локальних серверів у рядку меню macOS.
// Copyright (C) 2026 Golens
//
// Вільна програма: ви можете поширювати й змінювати її на умовах
// GNU General Public License версії 3 або, на ваш вибір, будь-якої
// пізнішої версії. Повний текст — у файлі LICENSE.
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import AppKit
import os

/// Повідомляє, чи вікно з цим виглядом зараз на екрані.
/// MenuBarExtra не знищує вигляд при закритті вікна і не робить його ключовим,
/// тому ні onAppear, ні сповіщення про активність не годяться. Надійний сигнал —
/// стан заслоненості вікна: він змінюється при кожному показі та приховуванні.
struct WindowVisibility: NSViewRepresentable {
    var onChange: (Bool) -> Void

    func makeNSView(context: Context) -> Probe {
        let probe = Probe()
        probe.onChange = onChange
        return probe
    }

    func updateNSView(_ probe: Probe, context: Context) {
        probe.onChange = onChange
    }

    final class Probe: NSView {
        var onChange: ((Bool) -> Void)?
        private var observer: NSObjectProtocol?
        private let log = Logger(subsystem: "com.aladin.Localscan", category: "window")

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            guard let window else { report(false); return }
            report(window.occlusionState.contains(.visible))
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
            ) { [weak self] note in
                // черга .main, тож ми вже на головному потоці — лише підтверджуємо це компілятору
                MainActor.assumeIsolated {
                    guard let self, let window = note.object as? NSWindow else { return }
                    self.report(window.occlusionState.contains(.visible))
                }
            }
        }

        private func report(_ visible: Bool) {
            log.notice("вікно на екрані: \(visible)")
            // не всередині оновлення SwiftUI — інакше попередження про зміну стану під час оновлення
            DispatchQueue.main.async { [onChange] in onChange?(visible) }
        }

        deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    }
}
