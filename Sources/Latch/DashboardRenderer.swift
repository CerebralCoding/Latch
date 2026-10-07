import Foundation

enum DashboardRenderer {
    static func render(_ model: inout DashboardModel, width: Int, height: Int) -> TerminalScreen {
        var screen = TerminalScreen(width: width, height: height)
        let width = screen.width
        let height = screen.height
        guard width >= 45, height >= 12 else {
            screen.put("Latch · terminal too small", x: 0, y: 0, style: .init(tone: .warning, bold: true))
            screen.put("Resize to at least 46 × 12. q: quit", x: 0, y: 2)
            return screen
        }
        let service = model.snapshot?.view.service
        let status = model.error != nil ? "DISCONNECTED" : service?.running == true ? "CONNECTED" : "OFFLINE"
        screen.fill(y: 0, style: .init(tone: .accent, bold: true))
        screen.put(" LATCH  \(BuildIdentity.version)  /  OPERATOR", x: 0, y: 0, style: .init(tone: .accent, bold: true))
        let badge = model.paused ? "DISPLAY FROZEN" : status
        screen.put(
            badge, x: max(31, width - badge.count - 1), y: 0,
            style: .init(tone: model.paused ? .warning : .accent, bold: true))
        screen.put(" OVERVIEW", x: 1, y: 2, style: .init(tone: .accent, bold: true))
        let shortcuts =
            (width >= 70 ? "refresh \(HumanOutput.number(model.interval))s  " : "") + "Tab Details  i Sensors  ? Help"
        screen.put(shortcuts, x: width - shortcuts.count - 1, y: 2, style: .init(tone: .muted))
        overview(&screen, model: model)
        if model.details { detailsOverlay(&screen, model: &model) }
        screen.fill(y: height - 2, style: .init(tone: model.error == nil ? .muted : .critical))
        let notice =
            model.error.map { "Snapshot failed: \($0) · retrying" }
            ?? (model.busy ? "Applying confirmed action…" : model.notice)
        screen.put(" " + notice, x: 0, y: height - 2, style: .init(tone: model.error == nil ? .muted : .critical))
        let footer: String
        if model.editingFilter {
            footer = "/\(model.filter)▏  Enter: apply  Esc: clear"
        } else if model.details {
            footer = " Tab close  ↑↓ scroll  Esc back  P prioritize  x cancel  q quit"
        } else {
            footer = " ↑↓ select  Enter/Tab details  / filter  s sort  h history  ? help  q quit"
        }
        screen.put(footer, x: 0, y: height - 1, style: .init(tone: .accent))
        switch model.modal {
        case .help: help(&screen, offset: &model.modalOffset)
        case .sensors:
            let text = sensorText(model, width: min(screen.width - 2, 90) - 4)
            overlay(
                &screen, title: "SENSORS & ADMISSION", text: text, tone: .accent,
                footer: "↑↓ scroll · i / Esc close", offset: &model.modalOffset)
        case nil: break
        }
        if let action = model.confirmation { confirmation(&screen, action: action, offset: &model.modalOffset) }
        return screen
    }

    private static func overview(_ screen: inout TerminalScreen, model: DashboardModel) {
        guard let snapshot = model.snapshot else {
            screen.put("Connecting to the scheduler…", x: 2, y: 5, style: .init(tone: .muted))
            return
        }
        let view = snapshot.view
        let running = view.jobs.filter { $0.state == "running" }
        let queued = view.jobs.filter { $0.queuePosition != nil }.count
        let parked = view.jobs.filter { $0.state == "parked" || $0.state == "waiting" }.count
        screen.put(
            "\(running.count) RUNNING    \(queued) QUEUED    \(parked) CHECKPOINT WAIT    \(HumanOutput.count(snapshot.totalJobs)) TOTAL JOBS",
            x: 2, y: 4, style: .init(bold: true))
        let age = view.sensorAgeSeconds.map { HumanOutput.duration(max(0, $0)) + " ago" } ?? "unavailable"
        let sampling = view.samplingPaused ? "paused: \(view.samplingPausedReason ?? "policy")" : "cached · \(age)"
        screen.put("Sensors \(sampling) · process latch \(view.processLatch)", x: 2, y: 5, style: .init(tone: .muted))
        if let alert = model.alerts.first {
            screen.put(
                alert.text + (model.alerts.count > 1 ? " (+\(model.alerts.count - 1) · i Sensors)" : ""), x: 2, y: 6,
                width: screen.width - 4, style: .init(tone: alert.tone, bold: true))
        } else {
            screen.put(
                "NORMAL · memory pressure \(view.sensors?.memoryPressure ?? "unavailable") · thermal \(view.sensors?.thermalState ?? "unavailable")",
                x: 2, y: 6, style: .init(tone: .good))
        }
        var y = screen.height >= 18 ? 8 : 7
        if screen.width >= 100, screen.height >= 34 {
            let chartWidth = (screen.width - 4) / 3
            let chartHeight = screen.height >= 42 ? 9 : 7
            for (index, metric) in DashboardMetric.allCases.enumerated() {
                chart(
                    &screen, model: model, metric: metric, x: 1 + (index % 3) * (chartWidth + 1),
                    y: y + (index / 3) * chartHeight, width: chartWidth, height: chartHeight)
            }
            y += chartHeight * 2
            screen.put(
                "1 column = 1 sensor sample → newest · gaps: paused/unavailable · fixed scales", x: 2,
                y: y, style: .init(tone: .muted))
            y += 2
        } else if screen.height - 2 - y >= DashboardMetric.allCases.count + 8 {
            for metric in DashboardMetric.allCases {
                let value = view.sensors.flatMap { metric.value($0) }
                let held = model.sensorHoldReason
                let tone = held == nil ? model.samples.last?.tones[metric] ?? metric.tone(value) : .muted
                let text = held == nil ? value.map { String(format: "%5.1f%@", $0, metric.unit) } ?? "    —" : "    —"
                screen.put(TerminalText.fit(metric.rawValue, width: 17) + text, x: 2, y: y, style: .init(tone: tone))
                let label =
                    held
                    ?? (metric == .ane
                        ? (view.sensors?.aneActivity?.source.label ?? "—")
                        : tone == .critical ? "high" : tone == .warning ? "watch" : value == nil ? "—" : "normal")
                screen.put(label, x: 29, y: y, style: .init(tone: tone))
                let chartX = 42
                let count = max(0, screen.width - chartX - 2)
                sparkline(&screen, samples: model.samples, metric: metric, x: chartX, y: y, width: count)
                y += 1
            }
            y += 1
        }
        let capacity = view.capacity
        if y < screen.height - 5 {
            screen.put(
                "Reservations  CPU \(capacity.reservedCPUCores)/\(capacity.totalCPUCores) cores · RAM \(HumanOutput.memory(Double(capacity.reservedMemoryMiB))) · parked \(HumanOutput.memory(Double(capacity.parkedResidentMemoryMiB)))",
                x: 2, y: y, width: screen.width - 4, style: .init(tone: .accent))
            y += 1
        }
        if y < screen.height - 5 {
            func watts(_ value: Double?) -> String {
                guard let value, value.isFinite, value >= 0 else { return "—" }
                return HumanOutput.number(value) + " W"
            }
            let sensors = view.sensors
            let label = model.sensorHoldReason == nil ? "Power" : "Last power"
            let power =
                "\(label)  CPU \(watts(sensors?.cpuWatts)) · GPU \(watts(sensors?.gpuWatts)) · ANE \(watts(sensors?.aneWatts))"
            for line in TerminalText.wrap(power, width: screen.width - 4).prefix(screen.height - 5 - y) {
                screen.put(line, x: 2, y: y, style: .init(tone: model.sensorHoldReason == nil ? .normal : .muted))
                y += 1
            }
        }
        if y < screen.height - 5 {
            screen.put(
                "\(model.sensorHoldReason == nil ? "Available" : "Last captured") RAM \(view.sensors.map { HumanOutput.memory(Double($0.memoryAvailableMiB)) } ?? "—") · disk \(rate(view.sensors?.diskBytesPerSecond))",
                x: 2, y: y, width: screen.width - 4)
            y += 1
        }
        jobs(&screen, model: model, y: y)
    }

    private static func chart(
        _ screen: inout TerminalScreen, model: DashboardModel, metric: DashboardMetric, x: Int, y: Int, width: Int,
        height: Int
    ) {
        let current = model.snapshot?.view.sensors.flatMap { metric.value($0) }
        let held = model.sensorHoldReason
        let tone = held == nil ? model.samples.last?.tones[metric] ?? metric.tone(current) : .muted
        let state =
            metric == .ane
            ? (model.snapshot?.view.sensors?.aneActivity?.source.label ?? "unavailable")
            : tone == .critical ? "high" : tone == .warning ? "watch" : current == nil ? "unavailable" : "normal"
        screen.box(x: x, y: y, width: width, height: height, title: metric.rawValue)
        let value = current.map { String(format: "%.1f%@", $0, metric.unit) } ?? "—"
        let reading = held.map { "\($0.capitalized) · last \(value)" } ?? "\(value)  \(state)"
        screen.put(reading, x: x + 2, y: y + 1, width: width - 4, style: .init(tone: tone, bold: true))
        let rows = height - 3
        let columns = width - 8
        let plot = DashboardChart.bars(samples: model.samples, metric: metric, width: columns, height: rows)
        screen.overlay(plot, x: x + 6, y: y + 2)
        screen.put(String(Int(metric.ceiling)), x: x + 1, y: y + 2, width: 4, style: .init(tone: .muted))
        screen.put("0", x: x + 3, y: y + height - 2, style: .init(tone: .muted))
    }

    private static func sparkline(
        _ screen: inout TerminalScreen, samples: [DashboardSample], metric: DashboardMetric, x: Int, y: Int, width: Int
    ) {
        let tail = samples.suffix(width)
        let glyphs = Array("▁▂▃▄▅▆▇█")
        for (index, sample) in tail.enumerated() {
            guard let value = sample.values[metric] else { continue }
            let level = Int((max(0, min(1, value / metric.ceiling)) * 7).rounded())
            screen.put(
                String(glyphs[level]), x: x + width - tail.count + index, y: y,
                style: .init(tone: sample.tones[metric] ?? .muted))
        }
    }

    private static func jobs(_ screen: inout TerminalScreen, model: DashboardModel, y: Int) {
        let height = screen.height - 2 - y
        guard height >= 3 else { return }
        var content = TerminalScreen(width: screen.width - 4, height: height - 2)
        let rows = model.jobs
        let wide = content.width >= 100
        let narrow = content.width < 70
        let header = content.height >= 4 ? 1 : 0
        if header > 0 {
            let prefix =
                wide
                ? "  POS  STATE       CLASS        ELAPSED   ID        NAME"
                : narrow ? "  STATE      ELAPSED  NAME" : "  POS  STATE       ELAPSED   NAME"
            content.put(prefix, x: 0, y: 0, style: .init(tone: .muted))
        }
        let count = content.height - header * 2
        let index = rows.firstIndex { $0.jobID == model.selectedID } ?? 0
        let start = min(max(0, index - count + 1), max(0, rows.count - count))
        if rows.isEmpty {
            content.put(
                model.filter.isEmpty ? "No jobs in this view." : "No matching jobs. / edits the filter.", x: 1,
                y: header,
                style: .init(tone: .muted))
        }
        for (offset, job) in rows.dropFirst(start).prefix(count).enumerated() {
            let selected = job.jobID == model.selectedID
            let tone: DashboardTone = job.state == "running" ? .good : job.state == "cancelling" ? .warning : .normal
            let style = TerminalStyle(tone: tone, bold: selected, selected: selected)
            let row = header + offset
            if selected { content.fill(y: row, style: style) }
            var text = selected ? "› " : "  "
            if !narrow { text += TerminalText.fit(job.queuePosition.map(String.init) ?? "—", width: 5) }
            text += TerminalText.fit(job.state, width: narrow ? 11 : 12)
            if wide { text += TerminalText.fit(job.classification, width: 13) }
            text += TerminalText.fit(HumanOutput.duration(job.elapsedSeconds), width: narrow ? 9 : 10)
            if wide { text += TerminalText.fit(String(job.jobID.prefix(8)), width: 10) }
            text += job.name
            content.put(text, x: 0, y: row, style: style)
        }
        if header > 0, let job = model.selected {
            content.put(
                job.blockerDetail ?? job.blockedBy
                    ?? (job.complete
                        ? "Retained result · Enter for output and outcome"
                        : "Enter for command, reservations, admission, and output"),
                x: 1, y: content.height - 1, style: .init(tone: .muted))
        }
        let title =
            "\(model.showHistory ? "JOB HISTORY" : "JOBS") · \(HumanOutput.count(rows.count)) · sort: \(model.sort.rawValue)"
            + (model.filter.isEmpty ? "" : " · /\(model.filter)")
        screen.overlay(content, x: 2, y: y + 1)
        screen.box(x: 1, y: y, width: screen.width - 2, height: height, title: title, tone: .accent)
        if rows.count > count {
            let range =
                " \(HumanOutput.count(start + 1))–\(HumanOutput.count(min(rows.count, start + count)))/\(HumanOutput.count(rows.count)) "
            screen.put(range, x: screen.width - range.count - 3, y: y + height - 1, style: .init(tone: .muted))
        }
    }

    private static func detailsOverlay(_ screen: inout TerminalScreen, model: inout DashboardModel) {
        let x = 2
        let y = 3
        let width = screen.width - 4
        let height = screen.height - 6
        var content = TerminalScreen(width: width - 2, height: height - 2)
        detail(&content, model: &model)
        screen.overlay(content, x: x + 1, y: y + 1)
        screen.box(x: x, y: y, width: width, height: height, title: "JOB DETAILS · Tab / Esc close", tone: .accent)
    }

    static func detailLines(_ model: DashboardModel, width: Int) -> [String] {
        guard let detail = model.retainedDetail, let snapshot = model.snapshot else {
            return ["This job left the current view. Esc returns to jobs."]
        }
        let job = detail.job
        let status = detail.current ? job.state : "Last observed: \(job.state) · no longer in queue/history"
        var lines = [
            job.name, job.jobID,
            "\(status) · \(job.classification) · elapsed \(HumanOutput.duration(job.elapsedSeconds))",
        ]
        if let pid = job.pid { lines.append("PID \(pid)") }
        lines.append("Submitted \(job.createdAt.formatted(date: .numeric, time: .standard))")
        if let finished = job.finishedAt {
            lines.append("Finished \(finished.formatted(date: .numeric, time: .standard))")
        }
        if let task = detail.task {
            let requirements = task.requirements
            lines += [
                "", job.complete || !detail.current ? "SAVED JOB REQUIREMENTS" : "ADMISSION",
                job.blockerDetail ?? job.blockedBy ?? "No current admission blocker.",
            ]
            if let seconds = job.cooldownRemainingSeconds {
                lines.append("Conditional cooldown remaining: \(HumanOutput.duration(seconds))")
            }
            lines.append(
                "Reservations: \(requirements.cpuCores) CPU cores · \(HumanOutput.memory(Double(requirements.memoryMiB))) memory"
            )
            lines.append(
                "GPU \(requirements.gpu ? "reserved" : "shared") · I/O \(requirements.io ? "reserved" : "shared") · bandwidth \(requirements.bandwidth ? "reserved" : "shared")"
            )
            if let guardrail = requirements.temperatureGuard {
                lines.append(
                    "Temperature limits: CPU ≤\(HumanOutput.temperature(guardrail.maxCPU)) · GPU ≤\(HumanOutput.temperature(guardrail.maxGPU)) · cooldown \(HumanOutput.duration(guardrail.cooldown))"
                )
            }
        }
        if let record = detail.record {
            lines += [
                "", "COMMAND",
                ([record.submission.executable] + record.submission.arguments).map { String(reflecting: $0) }.joined(
                    separator: " "), "Directory: \(record.submission.workingDirectory)",
            ]
        } else if let task = detail.task {
            lines += ["", "COMMAND", task.arguments.map { String(reflecting: $0) }.joined(separator: " ")]
        }
        if let sensors = snapshot.view.sensors {
            let limits = snapshot.view.quietLimits
            lines += [
                "", "MEASUREMENT QUIET LIMITS · cached machine readings",
                "CPU \(HumanOutput.percent(sensors.cpuActive)) / ≤\(HumanOutput.percent(limits.cpuActive)) · core \(HumanOutput.percent(sensors.busiestCore)) / ≤\(HumanOutput.percent(limits.busiestCore))",
                "GPU \(HumanOutput.percent(sensors.gpuActive)) / ≤\(HumanOutput.percent(limits.gpuActive))",
                HumanOutput.aneQuiet(sensors, limits: limits),
                "Disk \(rate(sensors.diskBytesPerSecond)) / ≤\(rate(limits.diskBytesPerSecond))",
                "Idle baseline: \(snapshot.view.idleBaseline == nil ? "not calibrated" : "calibrated") · memory \(sensors.memoryPressure) · thermal \(sensors.thermalState)",
            ]
        }
        lines += ["", "OUTPUT / RESULT"]
        lines += model.outputID == job.jobID ? model.outputLines : ["Loading retained output…"]
        return lines.flatMap { TerminalText.wrap($0, width: width) }
    }

    private static func detail(_ screen: inout TerminalScreen, model: inout DashboardModel) {
        screen.put("JOB DETAILS · Esc back", x: 2, y: 0, style: .init(tone: .accent, bold: true))
        let lines = detailLines(model, width: screen.width - 4)
        let count = max(0, screen.height - 2)
        model.detailOffset = max(0, min(model.detailOffset, max(0, lines.count - count)))
        for (index, line) in lines.dropFirst(model.detailOffset).prefix(count).enumerated() {
            screen.put(line, x: 2, y: 2 + index)
        }
        screen.put("\(model.detailOffset + 1)/\(lines.count)", x: screen.width - 14, y: 0, style: .init(tone: .muted))
    }

    private static func sensorText(_ model: DashboardModel, width: Int) -> String {
        guard let view = model.snapshot?.view else { return "Connecting to the scheduler…" }
        var lines = [
            "Cached scheduler readings", "",
            "Service: \(view.service.running ? "running" : "stopped") · PID \(view.service.pid.map(String.init) ?? "—") · revision \(view.service.serviceRevision.map(String.init) ?? "—")",
            "Queue: \(view.service.path)",
            "Process latch: \(view.processLatch) · admission freshness: \(view.sensorsFresh ? "fresh" : "not fresh")",
            "Sample age: \(view.sensorAgeSeconds.map { HumanOutput.duration(max(0, $0)) } ?? "unavailable") · sampling every second",
            "",
        ]
        if !model.alerts.isEmpty { lines += ["CURRENT NOTICES"] + model.alerts.map(\.text) + [""] }
        if let value = view.sensors {
            let baseline = view.idleBaseline
            let limits = view.quietLimits
            lines += [
                width >= 74
                    ? "RESOURCE             OBSERVED          IDLE BASELINE     QUIET LIMIT"
                    : "OBSERVED · IDLE BASELINE · QUIET LIMIT"
            ]
            func row(_ label: String, _ observed: String, _ idle: String, _ limit: String) -> String {
                if width < 74 { return "\(label): \(observed) · idle \(idle) · quiet ≤\(limit)" }
                return TerminalText.fit(label, width: 21) + TerminalText.fit(observed, width: 18)
                    + TerminalText.fit(idle, width: 18) + limit
            }
            lines += [
                row(
                    "CPU activity", HumanOutput.percent(value.cpuActive), HumanOutput.percent(baseline?.cpuActive),
                    HumanOutput.percent(limits.cpuActive)),
                row(
                    "Busiest core", HumanOutput.percent(value.busiestCore), HumanOutput.percent(baseline?.busiestCore),
                    HumanOutput.percent(limits.busiestCore)),
                row(
                    "GPU activity", HumanOutput.percent(value.gpuActive), HumanOutput.percent(baseline?.gpuActive),
                    HumanOutput.percent(limits.gpuActive)),
                row(
                    "ANE power", HumanOutput.power(value.aneWatts),
                    HumanOutput.power(baseline?.aneWatts), HumanOutput.power(limits.aneWatts)),
                row(
                    "Disk activity", rate(value.diskBytesPerSecond), rate(baseline?.diskBytesPerSecond),
                    rate(limits.diskBytesPerSecond)),
                "",
                "CPU power \(HumanOutput.power(value.cpuWatts)) · GPU power \(HumanOutput.power(value.gpuWatts))",
                "ANE activity: \(HumanOutput.percent(value.aneActivity?.fraction)) · \(value.aneActivity?.source.explanation ?? "utilization counters unavailable")",
                HumanOutput.aneQuiet(value, limits: limits),
                "CPU temperature \(HumanOutput.temperature(value.cpuTemperature)) · GPU \(HumanOutput.temperature(value.gpuTemperature))",
                "Thermal state: \(value.thermalState) · memory pressure: \(value.memoryPressure)",
                "Memory available: \(HumanOutput.memory(Double(value.memoryAvailableMiB))) / \(HumanOutput.memory(Double(value.memoryTotalMiB)))",
                "Captured: \(value.sampledAt.formatted(date: .numeric, time: .standard))",
                "",
                "Quiet limits apply to measurements only. Job temperature guards appear in job details.",
                "The same collector samples once per second, whether idle or running jobs.",
                "",
            ]
        }
        let capacity = view.capacity
        lines += [
            "RESERVATIONS · advisory, not enforced resource usage",
            "CPU: \(capacity.reservedCPUCores)/\(capacity.totalCPUCores) cores reserved · \(capacity.unreservedCPUCores) unreserved",
            "CPU admission headroom: ordinary \(capacity.ordinaryCPUHeadroom.map(String.init) ?? "—") · batch \(capacity.batchCPUHeadroom.map(String.init) ?? "—") cores",
            "Memory: \(HumanOutput.memory(Double(capacity.reservedMemoryMiB))) reserved · \(HumanOutput.memory(Double(capacity.parkedResidentMemoryMiB))) parked resident",
            "Memory admission headroom: \(capacity.memoryHeadroomMiB.map { HumanOutput.memory(Double($0)) } ?? "—")",
            "GPU \(capacity.gpuReserved ? "reserved" : "unreserved") · I/O \(capacity.ioReserved ? "reserved" : "unreserved") · bandwidth \(capacity.bandwidthReserved ? "reserved" : "unreserved")",
        ]
        return lines.joined(separator: "\n")
    }

    private static func help(_ screen: inout TerminalScreen, offset: inout Int) {
        let text = """
            OPERATOR KEYS
            Tab                      Open / close selected job details
            i / ?                    Sensors / Help modal; same key or Esc closes
            ↑ / ↓, j / k             Select jobs or scroll details and modals
            PgUp / PgDn, Home / End   Move a page, first / last
            Enter                    Open selected job details and output
            /                        Filter jobs by name, ID, state, class
            s / h                    Cycle sort / toggle retained history
            Space                    Freeze display (scheduler continues)
            + / -                    Faster / slower refresh, 0.5–60 seconds; saved
            P / x                    Prioritize / cancel selected job
            C / S                    Clear never-started / stop outstanding jobs
            q / Ctrl-C               Quit; jobs keep running
            Esc                      Close details or modal; clear filter on overview

            Every queue change requires y confirmation; Enter never confirms.
            Confirmation targets are fixed; newly arriving jobs are excluded.
            Total jobs counts current work and retained history.
            Shared scheduler readings arrive every second, including while idle.
            Running-job samples cannot earn idle calibration or measurement readiness.
            Missing readings stay gaps; inspection never starts another sampler.
            Charts retain 300 sensor samples, with a fixed 0–100% / 0–125°C scale.
            ANE uses compute or active-time counters when available; "floor est."
            means time above the lowest power/bandwidth request, not compute occupancy.
            Display watch/high bands: CPU/GPU/ANE 75/90%, RAM used 70/85%,
            CPU temperature 75/85°C, GPU temperature 70/80°C (5-unit hysteresis).
            These are visual cues. Admission uses the job's actual guardrails.
            Output is bounded; CLI output remains with its original terminal.
            NO_COLOR removes colors. State labels remain visible.

            Press ? or Esc to close.
            """
        overlay(&screen, title: "HELP", text: text, tone: .accent, footer: "↑↓ scroll · ? / Esc close", offset: &offset)
    }

    private static func confirmation(_ screen: inout TerminalScreen, action: DashboardAction, offset: inout Int) {
        let targets = action.names.joined(separator: "\n")
        let text =
            "\(action.title)\n\n\(action.explanation)\n\n\(targets)\n\nNew arrivals are excluded. The service stays running."
        overlay(
            &screen, title: "CONFIRM OPERATOR ACTION", text: text, tone: .warning,
            footer: "y confirm · n/Esc/Enter dismiss · ↑↓ scroll", offset: &offset)
    }

    private static func overlay(
        _ screen: inout TerminalScreen, title: String, text: String, tone: DashboardTone, footer: String,
        offset: inout Int
    ) {
        let width = min(screen.width - 2, 90)
        let x = (screen.width - width) / 2
        let lines = TerminalText.wrap(text, width: width - 4)
        let height = min(screen.height - 2, lines.count + 3)
        let y = (screen.height - height) / 2
        for row in y..<(y + height) { screen.put(String(repeating: " ", count: width), x: x, y: row) }
        screen.box(x: x, y: y, width: width, height: height, title: title, tone: tone)
        offset = max(0, min(offset, max(0, lines.count - (height - 3))))
        for (index, line) in lines.dropFirst(offset).prefix(height - 3).enumerated() {
            screen.put(line, x: x + 2, y: y + index + 1, width: width - 4)
        }
        screen.put(
            footer, x: x + 2,
            y: y + height - 2, width: width - 4, style: .init(tone: tone, bold: true))
    }

    private static func rate(_ value: Double?) -> String {
        value.map { HumanOutput.memory($0 / 1_048_576) + "/s" } ?? "—"
    }
}
