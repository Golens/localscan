// Localscan — монітор локальних серверів у рядку меню macOS.
// Copyright (C) 2026 Golens
//
// Вільна програма: ви можете поширювати й змінювати її на умовах
// GNU General Public License версії 3 або, на ваш вибір, будь-якої
// пізнішої версії. Повний текст — у файлі LICENSE.
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// Стан списку: одночасно розкрита лише одна картка і лише одне підтвердження
struct RowSelection {
    var expandedID: String?        // розкрита картка
    var confirmStopID: String?     // картка з підтвердженням зупинки
    var conflict: PortConflict?    // панель «порт зайнятий» для зупиненого проєкту

    mutating func toggleExpanded(_ id: String) {
        expandedID = expandedID == id ? nil : id
        confirmStopID = nil
        conflict = nil
    }

    mutating func toggleConfirmStop(_ id: String) {
        confirmStopID = confirmStopID == id ? nil : id
        conflict = nil
    }

    mutating func reset() { self = RowSelection() }
}

struct PortConflict {
    let projectID: String
    let holder: ServerProcess
    let altPort: Int
}

/// Стрілка праворуч у заголовку картки
private struct Chevron: View {
    let expanded: Bool
    var body: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
            .rotationEffect(.degrees(expanded ? 90 : 0))
            .frame(width: 14)
    }
}

/// Картка запущеного localhost; розкривається по кліку на заголовок
struct ServerRow: View {
    @EnvironmentObject var monitor: Monitor
    let server: ServerProcess
    @Binding var selection: RowSelection
    @State private var hover = false

    private var expanded: Bool { selection.expandedID == server.id }
    private var confirming: Bool { selection.confirmStopID == server.id }
    private var probe: ProbeResult? { monitor.health[server.id] }
    private var silent: Bool { probe == .silent || probe == .unreachable }
    private var busy: Bool { monitor.isBusy(server) }
    private var dotColor: Color { silent ? danger : busy ? .yellow : .green }
    private var isStopping: Bool { monitor.stopping.contains(server.id) }
    private var port: String { String(server.port) }   // рядком, інакше Text форматує «5 173»

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                // Заголовок — кнопка на всю ширину: клік спрацьовує з першого разу і по всій площі
                Button { withAnimation(.easeOut(duration: 0.15)) { selection.toggleExpanded(server.id) } } label: {
                    HStack(spacing: 12) {
                        Circle().fill(dotColor)
                            .frame(width: 8, height: 8)
                            .shadow(color: dotColor.opacity(0.8), radius: 4)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 8) {
                                Text(":\(port)").font(.system(size: 13, weight: .bold)).monospacedDigit()
                                Text("\(server.framework) · \(server.command)").foregroundStyle(.secondary).lineLimit(1)
                            }
                            // проблемний стан замість шляху: інакше підпис тисне назву і обрізається
                            if isStopping {
                                HStack(spacing: 5) {
                                    ProgressView().controlSize(.mini)
                                    Text("Stopping…").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                                }
                            } else if probe == .silent {
                                Text("not responding to requests")
                                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(danger).lineLimit(1)
                            } else if probe == .unreachable {
                                Text("the port refuses connections")
                                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(danger).lineLimit(1)
                            } else if busy {
                                Text("heavy CPU for \(monitor.busyFor(server))")
                                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(warm).lineLimit(1)
                            } else {
                                Text("\(server.shortCwd) · \(formatUptime(since: server.startedAt))")
                                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        Spacer(minLength: 8)
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(formatBytes(server.totalBytes)).font(.system(size: 13, weight: .semibold)).monospacedDigit()
                            Text("CPU \(Int(server.totalCPU))%").font(.system(size: 11))
                                .foregroundStyle(server.totalCPU > 20 ? warm : .secondary)
                        }
                        Chevron(expanded: expanded)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(expanded ? "Collapse" : "Show details")

                Button { withAnimation(.easeOut(duration: 0.15)) { selection.toggleConfirmStop(server.id) } } label: {
                    Image(systemName: confirming ? "xmark.circle.fill" : "xmark")
                        .font(.system(size: 11, weight: .bold)).foregroundStyle(.red.opacity(0.85))
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.plain).glassCard(10)
                .help(confirming ? "Cancel" : "Stop")
                .disabled(isStopping)
            }

            if confirming { confirmBar }
            if monitor.stubborn == server.id { stubbornBar }
            if expanded { details }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .glassCard()
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(hover || expanded ? accent : .clear))
        .onHover { hover = $0 }
        .opacity(isStopping ? 0.55 : 1)   // видно, що команду прийнято
        .onTapGesture { }   // клік усередині картки не доходить до фону вікна (там він усе згортає)
    }

    /// Підтвердження всередині картки: системний діалог у вікні MenuBarExtra закриває вікно
    private var confirmBar: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Stop :\(port)?").font(.system(size: 12, weight: .semibold))
                Text("\(server.framework) · \(server.shortCwd)").font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Button("Cancel") { withAnimation(.easeOut(duration: 0.15)) { selection.confirmStopID = nil } }
            Button("Stop") { monitor.stop(server); selection.reset() }
                .tint(.red).buttonStyle(.borderedProminent)
        }
        .padding(10)
        .background(Color.red.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
    }

    /// М'яка зупинка не спрацювала — пояснюємо і пропонуємо примусову
    private var stubbornBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("The server did not quit within 3 seconds", systemImage: "exclamationmark.triangle")
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(warm)
            Text("The process is ignoring the normal stop. A forced stop always works, but unsaved data will be lost.")
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") { monitor.cancelForceStop(server) }
                Button("Force stop") { monitor.forceStop(server); selection.reset() }
                    .tint(danger).buttonStyle(.borderedProminent)
            }
        }
        .padding(10)
        .background(warm.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            HStack(spacing: 8) {
                Button { monitor.check(server) } label: {
                    Label(monitor.checking.contains(server.id) ? "Checking…" : "Check", systemImage: "stethoscope")
                        .font(.system(size: 12))
                }
                .disabled(monitor.checking.contains(server.id))
                Spacer()
                if !server.cwd.isEmpty && !server.fullCommand.isEmpty {
                    Button { monitor.restart(server) } label: {
                        Label("Restart", systemImage: "arrow.clockwise")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .tint(accent)
                }
            }
            if probe == .responding {
                Label("Checked: the server responds", systemImage: "checkmark.circle")
                    .font(.system(size: 11)).foregroundStyle(accent)
            }
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Folder").font(.system(size: 11)).foregroundStyle(.secondary)
                    Text(server.cwd.isEmpty ? String(localized: "unknown") : server.cwd)
                        .font(.system(size: 12, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 8)
                if !server.cwd.isEmpty {
                    Button("Show in Finder") { monitor.revealInFinder(server.cwd) }.font(.caption)
                }
            }
            Button { monitor.openInBrowser(server) } label: {
                Label("Open localhost:\(port) in browser", systemImage: "arrow.up.right.square")
                    .font(.system(size: 12, weight: .semibold)).frame(maxWidth: .infinity)
            }
            .tint(accent).buttonStyle(.borderedProminent)
            if !server.children.isEmpty {
                HStack {
                    Text("Child processes · \(server.children.count)")
                    Spacer()
                    Text("total \(formatBytes(server.totalBytes))")
                }.font(.system(size: 11)).foregroundStyle(.secondary)
                ForEach(server.children) { c in
                    HStack {
                        Text(c.name).foregroundStyle(.secondary)
                        Spacer()
                        Text(formatBytes(c.rssBytes)).monospacedDigit()
                    }.font(.system(size: 12)).padding(.leading, 12)
                }
            }
            if let peak = monitor.sessionPeak[server.cwd + "|" + server.fullCommand] {
                HStack {
                    Text("Peak memory this session").foregroundStyle(.secondary)
                    Spacer()
                    Text(formatBytes(peak)).foregroundStyle(warm).fontWeight(.bold).monospacedDigit()
                }
                .font(.system(size: 12))
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(warm.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }
}

/// Картка зупиненого проєкту; розкривається по кліку на заголовок
struct StoppedRow: View {
    @EnvironmentObject var monitor: Monitor
    let project: SavedProject
    @Binding var selection: RowSelection
    @State private var hover = false

    private var expanded: Bool { selection.expandedID == project.id }
    private var conflict: PortConflict? { selection.conflict?.projectID == project.id ? selection.conflict : nil }
    private var port: String { String(project.lastPort) }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Button { withAnimation(.easeOut(duration: 0.15)) { selection.toggleExpanded(project.id) } } label: {
                    HStack(spacing: 12) {
                        Circle().fill(.secondary).frame(width: 8, height: 8)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 8) {
                                Text(":\(port)").font(.system(size: 13, weight: .bold)).monospacedDigit()
                                Text(project.framework).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Text("\(project.shortCwd) · stopped \(project.stoppedAt?.formatted(.relative(presentation: .named)) ?? "")")
                                .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        Chevron(expanded: expanded)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(expanded ? "Collapse" : "Show details")

                Button(action: launchTapped) {
                    Label("Start", systemImage: "play.fill").font(.system(size: 12, weight: .semibold))
                }
                .tint(accent).buttonStyle(.borderedProminent)
                Button { monitor.forget(project); selection.reset() } label: { Image(systemName: "trash").font(.system(size: 11)) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Forget project")
            }

            if let c = conflict { conflictPanel(c) }
            if expanded { details }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .glassCard()
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(hover || expanded ? accent : .clear))
        .onHover { hover = $0 }
        .onTapGesture { }
    }

    private func launchTapped() {
        if let h = monitor.holder(of: project.lastPort) {
            withAnimation(.easeOut(duration: 0.15)) {
                selection.confirmStopID = nil
                selection.conflict = PortConflict(projectID: project.id, holder: h,
                                                  altPort: ProcessScanner.nextFreePort(after: project.lastPort))
            }
        } else {
            monitor.launch(project)
            selection.reset()
        }
    }

    private func conflictPanel(_ c: PortConflict) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Port :\(port) is busy — held by \(c.holder.framework) in \(c.holder.shortCwd)", systemImage: "exclamationmark.triangle")
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(warm)
            Button("Start on free port :\(String(c.altPort))") { monitor.launch(project, altPort: c.altPort); selection.reset() }
                .tint(accent).buttonStyle(.borderedProminent).frame(maxWidth: .infinity)
            Button("Stop that project and start on :\(port)") {
                monitor.stop(c.holder)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { monitor.launch(project) }
                selection.reset()
            }.frame(maxWidth: .infinity)
            Button("Cancel") { withAnimation(.easeOut(duration: 0.15)) { selection.conflict = nil } }.font(.caption)
            Text("Another port works if the project reads the PORT variable, as Next, Vite and Express do.")
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .padding(10)
        .background(warm.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Folder").font(.system(size: 11)).foregroundStyle(.secondary)
                    Text(project.cwd).font(.system(size: 12, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 8)
                Button("Show in Finder") { monitor.revealInFinder(project.cwd) }.font(.caption)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Launch command").font(.system(size: 11)).foregroundStyle(.secondary)
                Text(project.launchCommand).font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled).lineLimit(3).truncationMode(.middle)
            }
            HStack {
                Text("Last seen").foregroundStyle(.secondary)
                Spacer()
                Text(project.lastSeen.formatted(date: .abbreviated, time: .shortened)).monospacedDigit()
            }.font(.system(size: 12))
            HStack {
                Text("Peak memory").foregroundStyle(.secondary)
                Spacer()
                Text(formatBytes(project.peakBytes)).foregroundStyle(warm).fontWeight(.bold).monospacedDigit()
            }
            .font(.system(size: 12))
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(warm.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
            if let log = monitor.logs[project.id], !log.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Recent log lines").font(.system(size: 11)).foregroundStyle(.secondary)
                    Text(log.suffix(8).joined(separator: "\n"))
                        .font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                }
            }
        }
    }
}
