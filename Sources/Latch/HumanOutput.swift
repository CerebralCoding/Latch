import Darwin
import Foundation

enum HumanOutput {
    static let about = """
        Latch \(BuildIdentity.version)
        Local workload scheduler for autonomous agents sharing an Apple Silicon Mac.

        Created by Sebastian Christiansen
        Copyright © 2026 Sebastian Christiansen
        License: MIT
        Contact: mail@cerebralcoding.com
        Source: https://github.com/CerebralCoding/Latch

        If Latch helps your work, consider sponsoring its development:
        https://github.com/sponsors/CerebralCoding
        """

    static var terminalWidth: Int {
        var size = winsize()
        guard ioctl(STDOUT_FILENO, TIOCGWINSZ, &size) == 0, size.ws_col > 0 else { return 100 }
        return max(20, min(240, Int(size.ws_col)))
    }

    static func safe(_ value: String) -> String {
        value.unicodeScalars.map { scalar in
            switch scalar.value {
            case 10: return "\\n"
            case 13: return "\\r"
            case 9: return "\\t"
            default:
                switch scalar.properties.generalCategory {
                case .control, .format, .lineSeparator, .paragraphSeparator:
                    return "\\u{\(String(scalar.value, radix: 16))}"
                default: return String(scalar)
                }
            }
        }.joined()
    }

    static func number(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "unavailable" }
        return String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    static func percent(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "unavailable" }
        return number(value * 100) + "%"
    }

    static func temperature(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "unavailable" }
        return number(value) + "°C"
    }

    static func memory(_ mib: Double) -> String {
        mib >= 1024 ? number(mib / 1024) + " GiB" : number(mib) + " MiB"
    }

    static func duration(_ seconds: Double?) -> String {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return "unknown" }
        if seconds < 60 { return number(seconds) + "s" }
        if seconds < 3600 { return "\(Int(seconds / 60))m \(Int(seconds.truncatingRemainder(dividingBy: 60)))s" }
        return "\(Int(seconds / 3600))h \(Int(seconds.truncatingRemainder(dividingBy: 3600) / 60))m"
    }

    static func sensors(_ value: SensorSnapshot, verbose: Bool) -> String {
        var lines = [
            "CPU \(temperature(value.cpuTemperature)) · GPU \(temperature(value.gpuTemperature))",
            "Activity CPU \(percent(value.cpuActive)) · GPU \(percent(value.gpuActive))",
            "Memory \(memory(Double(value.memoryAvailableMiB))) available · pressure \(safe(value.memoryPressure))",
            "Thermal \(safe(value.thermalState))",
        ]
        if verbose {
            lines += [
                "Cores \(value.cpuCores) · busiest core \(percent(value.busiestCore))",
                "Memory total \(memory(Double(value.memoryTotalMiB)))",
                "ANE \(number(value.aneWatts)) W",
                "Disk \(value.diskBytesPerSecond.map { memory($0 / 1_048_576) + "/s" } ?? "unavailable")",
                "Sampled \(value.sampledAt.formatted(.iso8601))",
            ]
        }
        if !value.unavailable.isEmpty {
            lines.append("Unavailable: " + safe(value.unavailable.joined(separator: "; ")))
        }
        return lines.joined(separator: "\n")
    }

    static func service(_ value: SchedulerService.Status, verbose: Bool) -> String {
        var lines = [value.running ? "Latch service running" : "Latch service stopped"]
        if let pid = value.pid {
            lines.append("PID \(pid) · scheduler revision \(value.serviceRevision.map(String.init) ?? "unknown")")
        }
        if verbose {
            let paths = InstallationPaths()
            lines += [
                "Command version \(BuildIdentity.version)", "Queue \(safe(value.path))",
                "Executable \(safe(paths.executable.path))", "State \(safe(paths.state.path))",
                "Logs \(safe(paths.logs.path))", "Label \(ServiceInstallation.label)",
            ]
        }
        if !value.running { lines.append("Use latch service start to start the installed service.") }
        return lines.joined(separator: "\n")
    }

    static func view(_ value: SchedulerView, verbose: Bool, width: Int = terminalWidth) -> String {
        let running = value.jobs.filter { $0.state == "running" }
        let queued = value.jobs.filter { $0.state == "queued" || $0.state == "waiting" }
        let parked = value.jobs.filter { $0.state == "parked" }
        let cancelling = value.jobs.filter { $0.state == "cancelling" }
        var lines = [
            "Latch · service \(value.service.running ? "running" : "stopped")", "",
            "Jobs       \(running.count) running · \(queued.count) queued · \(parked.count) parked · \(cancelling.count) cancelling",
        ]
        if !value.service.running {
            lines.append("Admission  Service stopped; queued work awaits recovery")
        } else if let next = value.jobs.first(where: { $0.jobID == value.nextTaskID }) {
            lines.append("Next       \(safe(next.name)) (\(next.classification))")
            lines.append(
                "Admission  \(safe(next.blockerDetail ?? next.blockedBy ?? "Eligible at this snapshot; admission is not reserved"))"
            )
            if let remaining = next.cooldownRemainingSeconds, remaining > 0 {
                lines.append(
                    "Cooldown   \(duration(remaining)) remaining if conditions stay satisfied; not a start-time estimate"
                )
            }
        } else if !running.isEmpty {
            lines.append("Admission  No queued work")
        } else {
            lines.append(
                value.jobs.isEmpty
                    ? "Admission  No outstanding work" : "Admission  Awaiting checkpoint or supervisor state")
        }

        if let error = value.sensorError {
            lines.append("Sensors    Failed: \(safe(error))")
        } else if value.samplingPaused {
            lines.append(
                "Sensors    Sampling paused during \(value.samplingPausedReason ?? "exclusive work")\(value.sensorAgeSeconds.map { "; last readings " + duration($0) + " ago" } ?? "")"
            )
        } else if value.service.running, value.jobs.isEmpty, value.sensors != nil,
            let age = value.sensorAgeSeconds,
            (0...(SchedulingPolicy.idleSampleInterval + SchedulingPolicy.maximumSampleAge)).contains(age)
        {
            lines.append(
                "Sensors    Idle cached readings \(duration(age)) old; sampling every \(duration(SchedulingPolicy.idleSampleInterval))"
            )
        } else if value.sensorsFresh {
            lines.append("Sensors    Cached readings \(duration(value.sensorAgeSeconds)) old")
        } else {
            lines.append(
                "Sensors    \(value.sensors == nil ? "No readings yet" : "Sampling \(value.service.running ? "overdue" : "stopped"); last readings \(duration(value.sensorAgeSeconds)) ago")"
            )
        }
        if let sensors = value.sensors {
            lines.append(
                "\(value.sensorsFresh ? "Readings" : "Last read")  CPU \(temperature(sensors.cpuTemperature)) · GPU \(temperature(sensors.gpuTemperature)) · memory pressure \(safe(sensors.memoryPressure))"
            )
            if !sensors.unavailable.isEmpty {
                lines.append("Unavailable \(safe(sensors.unavailable.joined(separator: "; ")))")
            }
        }
        if verbose {
            lines += ["", list(value.jobs, verbose: true, width: width)]
        } else if value.jobs.isEmpty {
            lines += ["", "No outstanding jobs."]
        } else {
            let ordered = running + value.jobs.filter { $0.state != "running" }
            lines += ["", "Work"]
            lines += ordered.prefix(6).map { "  \($0.state) · \(safe($0.name)) (\($0.classification))" }
            if ordered.count > 6 { lines.append("\(ordered.count - 6) more jobs · use --verbose for all") }
            lines.append("Use latch list for copyable job IDs.")
        }
        if verbose {
            lines += [
                "", "Service", service(value.service, verbose: true), "", "Reservations (advisory)",
                "CPU \(value.capacity.reservedCPUCores)/\(value.capacity.totalCPUCores) cores reserved · \(value.capacity.unreservedCPUCores) unreserved",
                "Ordinary CPU headroom \(value.capacity.ordinaryCPUHeadroom.map(String.init) ?? "unknown") · CLI batch headroom \(value.capacity.batchCPUHeadroom.map(String.init) ?? "unknown")",
                "Reserved memory \(memory(Double(value.capacity.reservedMemoryMiB))) · additional headroom \(value.capacity.memoryHeadroomMiB.map { memory(Double($0)) } ?? "unknown")",
                "Parked resident memory \(memory(Double(value.capacity.parkedResidentMemoryMiB)))",
                "GPU \(value.capacity.gpuReserved ? "reserved" : "unreserved") · disk I/O \(value.capacity.ioReserved ? "reserved" : "unreserved") · bandwidth \(value.capacity.bandwidthReserved ? "reserved" : "unreserved")",
                "Process latch \(value.processLatch) · capacity alone does not imply eligibility",
            ]
            if let sensors = value.sensors {
                lines += [
                    "", "\(value.sensorsFresh ? "Cached" : "Last captured") sensor details",
                    self.sensors(sensors, verbose: true),
                ]
            }
            lines += [
                "", "Measurement quiet limits",
                "CPU \(percent(value.quietLimits.cpuActive)) · busiest core \(percent(value.quietLimits.busiestCore)) · GPU \(percent(value.quietLimits.gpuActive))",
                "ANE \(number(value.quietLimits.aneWatts)) W · disk \(memory(value.quietLimits.diskBytesPerSecond / 1_048_576))/s",
                value.idleBaseline.map {
                    "Idle baseline: CPU \(percent($0.cpuActive)) · GPU \(percent($0.gpuActive)) · \($0.calibrationSamples) calibration samples"
                } ?? "Idle baseline: not calibrated",
            ]
            for task in value.tasks {
                lines += [
                    "",
                    "Job \(task.task.id): \(safe(task.blockerDetail ?? (task.task.state == .queued ? "eligible at this snapshot" : task.task.state.rawValue)))",
                ]
                lines.append(
                    "State \(task.task.state.rawValue) · PID \(task.task.pid) · CPU \(task.task.requirements.cpuCores) cores · memory \(memory(Double(task.task.requirements.memoryMiB)))"
                )
                lines.append(
                    "Arguments " + task.task.arguments.map { safe(String(reflecting: $0)) }.joined(separator: " "))
                if let guardrail = task.task.requirements.temperatureGuard {
                    lines.append(
                        "Guard CPU ≤\(temperature(guardrail.maxCPU)) · GPU ≤\(temperature(guardrail.maxGPU)) · cooldown \(duration(guardrail.cooldown))"
                    )
                }
            }
        }
        return wrap(lines.joined(separator: "\n"), width: width)
    }

    static func list(_ jobs: [JobSummary], verbose: Bool, width: Int = terminalWidth) -> String {
        guard !jobs.isEmpty else { return "No outstanding jobs." }
        let ordered = jobs.filter { $0.state == "running" } + jobs.filter { $0.state != "running" }
        let shown = verbose ? ordered : Array(ordered.prefix(10))
        var lines: [String] = []
        if width >= 100 {
            let rows =
                [["JOB ID", "STATE", "CLASS", "QUEUE", "AGE", "NAME"]]
                + shown.map {
                    [
                        $0.jobID, $0.state, $0.classification, $0.queuePosition.map(String.init) ?? "-",
                        duration($0.elapsedSeconds), safe($0.name),
                    ]
                }
            let sizes = (0..<5).map { index in rows.map { displayWidth($0[index]) }.max() ?? 0 }
            lines = rows.map { row in
                (0..<5).map { index in
                    row[index] + String(repeating: " ", count: sizes[index] - displayWidth(row[index]) + 2)
                }.joined() + row[5]
            }
        } else {
            for job in shown {
                lines += [
                    job.jobID,
                    "  \(job.state) · \(job.classification) · \(job.queuePosition.map { "queue \($0) · " } ?? "")\(duration(job.elapsedSeconds))",
                    "  \(safe(job.name))",
                ]
            }
        }
        if jobs.count > shown.count {
            lines.append("\(jobs.count - shown.count) more outstanding jobs · use --verbose for all")
        }
        return wrap(lines.joined(separator: "\n"), width: width)
    }

    private static func displayWidth(_ text: String) -> Int {
        text.reduce(0) { total, character in
            let scalars = character.unicodeScalars
            if scalars.contains(where: { $0.properties.isEmojiPresentation || $0.value == 0xfe0f }) { return total + 2 }
            return total
                + scalars.reduce(0) { count, scalar in
                    let width = wcwidth(wchar_t(scalar.value))
                    if width >= 0 { return count + Int(width) }
                    // The C locale may not recognize Unicode widths.
                    if [.nonspacingMark, .enclosingMark].contains(scalar.properties.generalCategory) { return count }
                    let wide =
                        (0x1100...0x115f).contains(scalar.value) || (0x2e80...0xa4cf).contains(scalar.value)
                        || (0xac00...0xd7a3).contains(scalar.value) || (0xf900...0xfaff).contains(scalar.value)
                        || (0xff01...0xff60).contains(scalar.value) || (0x20000...0x3fffd).contains(scalar.value)
                    return count + (wide ? 2 : 1)
                }
        }
    }

    static func wrap(_ text: String, width: Int) -> String {
        let width = max(20, width)
        return text.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            if UUID(uuidString: String(line)) != nil { return String(line) }
            var result = ""
            var column = 0
            for character in line {
                let count = displayWidth(String(character))
                if column + count > width, column > 0 {
                    result += "\n"
                    column = 0
                }
                result.append(character)
                column += count
            }
            return result
        }.joined(separator: "\n")
    }
}
