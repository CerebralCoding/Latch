import CoreGraphics
import CoreText
import Darwin
import Foundation
import ImageIO
import Testing

@testable import Latch

@Suite struct DashboardTests {
    @Test func options() throws {
        #expect(try Options(arguments: ["tui"]).refreshInterval == nil)
        let options = try Options(arguments: ["tui", "--interval=0.5", "--file", "/queue"])
        #expect(options.command == .tui)
        #expect(options.file == "/queue")
        #expect(options.refreshInterval == 0.5)
        for arguments in [
            ["tui", "--interval", "nan"], ["tui", "--interval", "0"], ["tui", "--interval", "61"],
            ["tui", "--json"], ["tui", "--verbose"], ["view", "--interval", "1"],
            ["tui", "--interval=1", "--interval=2"], ["tui", "--", "job"],
        ] { #expect(throws: LatchError.self) { try Options(arguments: arguments) } }
        #expect(CLIHelp.text(for: .tui).contains("cached"))
    }

    @Test func fragmentedInputAndPaste() {
        var input = TerminalInput()
        #expect(input.feed(Data([27])).isEmpty)
        #expect(input.feed(Data("[".utf8)).isEmpty)
        #expect(input.feed(Data("A".utf8)) == [.up])
        #expect(input.feed(Data("\u{1B}[6~\u{1B}[H\t\r".utf8)) == [.pageDown, .home, .tab, .enter])
        #expect(input.feed(Data("\u{1B}[200~SyxPq\n\u{1B}[20".utf8)).isEmpty)
        #expect(input.feed(Data("1~".utf8)).isEmpty)
        #expect(input.feed(Data("q".utf8)) == [.character("q")])
        #expect(input.feed(Data("\u{1B}x\u{1B}[99~".utf8)).isEmpty)
        #expect(input.feed(Data([27]), flushEscape: true) == [.escape])
        #expect(input.feed(Data([0xC3])).isEmpty)
        #expect(input.feed(Data([0xA6])) == [.character("æ")])
        #expect(input.feed(Data([3, 26])) == [.quit, .suspend])
    }

    @Test func refreshPreferencesValidateAndPersist() throws {
        let f = try Fixture()
        let environment = ["XDG_CONFIG_HOME": f.directory.path]
        let preferences = DashboardPreferences(environment: environment)
        #expect(preferences.loadInterval() == 1)
        try preferences.saveInterval(4)
        #expect(DashboardPreferences(environment: environment).loadInterval() == 4)
        for value in [0.0, 61, Double.nan, .infinity] {
            #expect(throws: LatchError.self) { try preferences.saveInterval(value) }
            #expect(preferences.loadInterval() == 4)
        }
        for text in ["broken", "{}", "{\"refreshInterval\":0}", "{\"refreshInterval\":61}"] {
            try Data(text.utf8).write(to: preferences.url)
            #expect(preferences.loadInterval() == 1)
        }
        try preferences.saveInterval(0.5)
        #expect(preferences.loadInterval() == 0.5)
        for environment in [[:], ["XDG_CONFIG_HOME": "relative"]] {
            #expect(
                DashboardPreferences(environment: environment, home: f.directory).url
                    == f.directory.appendingPathComponent(".config/latch/tui.json"))
        }
    }

    @Test func safeTerminalCellsAndIncrementalRendering() {
        let unsafe = "build\n\u{1B}]52;c;secret\u{7}\u{202E}"
        var screen = TerminalScreen(width: 16, height: 3)
        screen.put(unsafe, x: 0, y: 0)
        screen.put("界🙂é", x: 0, y: 1)
        #expect(!screen.plain.contains("\u{1B}"))
        #expect(!screen.plain.contains("\u{7}"))
        #expect(!screen.plain.contains("\u{202E}"))
        #expect(screen.cells[1][1].text.isEmpty)
        #expect(screen.cells[1][3].text.isEmpty)
        let previous = screen
        #expect(screen.ansi(previous: previous, color: true).isEmpty)
        screen.put("x", x: 1, y: 1, style: .init(tone: .critical))
        #expect(screen.cells[1][0].text == " ")
        let update = screen.ansi(previous: previous, color: false)
        #expect(update.contains("\u{1B}[2;1H"))
        #expect(!update.contains("\u{1B}[1;1H"))
        #expect(!update.contains("38;5"))
        #expect(TerminalText.fit("界a", width: 2) == "界")
        screen.put("界", x: 1, y: 2)
        screen.put("界", x: 0, y: 2)
        #expect(screen.cells[2][2].text == " ")
        #expect(TerminalText.safe("\u{200B}\u{2060}").contains("\\u{200b}"))
        #expect(TerminalText.safe("\u{0301}") == "\\u{301}")
    }

    @Test func samplesAreNotFabricatedFromCachedOrPausedReadings() {
        var model = DashboardModel(interval: 1)
        var snapshot = Self.snapshot()
        model.ingest(snapshot)
        model.ingest(snapshot)
        #expect(model.samples.count == 1)
        #expect(model.samples.last?.values[.cpu] == 12)
        snapshot.view.samplingPaused = true
        snapshot.view.samplingPausedReason = "exclusive work"
        snapshot.view.sensorAgeSeconds = 100
        model.ingest(snapshot)
        model.ingest(snapshot)
        #expect(model.samples.count == 2)
        #expect(model.samples.last?.values.isEmpty == true)
        #expect(!model.alerts.contains { $0.id == "stale" })
        snapshot.view.sensors?.memoryPressure = "critical"
        model.ingest(snapshot)
        #expect(model.alerts.first?.id == "memory")
        snapshot.view.samplingPaused = false
        snapshot.view.sensorAgeSeconds = 0
        snapshot.view.sensors?.uptime += 101
        snapshot.view.sensors?.gpuActive = nil
        model.ingest(snapshot)
        #expect(model.samples.count == 3)
        #expect(model.samples.last?.values[.gpu] == nil)
        #expect(model.samples.last?.values[.cpu] == 12)
        #expect(DashboardMetric.cpu.tone(87, previous: .critical) == .critical)
        #expect(DashboardMetric.cpu.tone(84, previous: .critical) == .warning)
    }

    @Test func alertsTrackCurrentPressureAndSamplesStayBounded() {
        var model = DashboardModel(interval: 1)
        var snapshot = Self.snapshot()
        model.ingest(snapshot)
        snapshot.view.sensors?.memoryPressure = "critical"
        model.ingest(snapshot)
        model.ingest(snapshot)
        #expect(model.alerts.filter { $0.id == "memory" }.count == 1)
        snapshot.view.sensors?.memoryPressure = "normal"
        model.ingest(snapshot)
        #expect(!model.alerts.contains { $0.id == "memory" })
        for index in 0..<400 {
            snapshot.view.sensors?.uptime = 1000 + Double(index)
            model.ingest(snapshot)
        }
        #expect(model.samples.count == 300)
        model.failed("offline")
        model.failed("offline")
        #expect(model.error == "offline")
        #expect(model.samples.count == 300)
        #expect(model.samples.last?.values.isEmpty == true)
        model.ingest(snapshot)
        #expect(model.error == nil)
    }

    @Test func stableSelectionFilteringAndHistory() {
        var model = DashboardModel(interval: 1)
        var snapshot = Self.snapshot()
        model.ingest(snapshot)
        model.selectedID = snapshot.view.jobs[1].jobID
        model.sort = .name
        model.reconcileSelection()
        #expect(model.selected?.name == "Release benchmark")
        model.filter = "ORDINARY"
        model.reconcileSelection()
        #expect(model.jobs.count == 1)
        #expect(model.selected?.name == "Swift build")
        model.details = true
        snapshot.view.jobs.removeAll()
        model.ingest(snapshot)
        #expect(model.selected?.name == "Swift build")
        #expect(model.retainedDetail?.current == false)
        #expect(model.selectedID != nil)
        let retained = DashboardRenderer.detailLines(model, width: 100).joined(separator: "\n")
        #expect(retained.contains("Last observed: running"))
        #expect(retained.contains("/usr/bin/swift"))
        model.prepare(.cancel)
        #expect(model.confirmation == nil)
    }

    @Test func confirmationsCaptureTargetsAndRequireExplicitYes() throws {
        var model = DashboardModel(interval: 1)
        model.ingest(Self.snapshot())
        var pending: DashboardAction?
        _ = OperatorDashboard.handle(.character("S"), model: &model, pending: &pending)
        let action = try #require(model.confirmation)
        #expect(action.ids.count == 2)
        _ = OperatorDashboard.handle(.enter, model: &model, pending: &pending)
        #expect(pending == nil)
        #expect(model.confirmation == nil)
        _ = OperatorDashboard.handle(.character("S"), model: &model, pending: &pending)
        _ = OperatorDashboard.handle(.character("y"), model: &model, pending: &pending)
        #expect(pending == action)
        #expect(model.busy)
        _ = OperatorDashboard.handle(.character("S"), model: &model, pending: &pending)
        #expect(model.confirmation == nil)
        model.busy = false
        model.paused = true
        model.prepare(.stop)
        #expect(model.confirmation == nil)
        model.paused = false
        model.failed("service unavailable")
        model.prepare(.stop)
        #expect(model.confirmation == nil)
    }

    @Test func overviewNavigationAndNestedModalsPreserveContext() {
        var model = Self.populatedModel()
        var pending: DashboardAction?
        func press(_ key: TerminalKey) {
            #expect(!OperatorDashboard.handle(key, model: &model, pending: &pending))
        }
        press(.down)
        let selected = model.selectedID
        press(.enter)
        press(.down)
        #expect(model.details)
        #expect(model.detailOffset == 1)
        for modal in [DashboardModel.Modal.sensors, .help] {
            let key = TerminalKey.character(modal == .sensors ? "i" : "?")
            press(key)
            #expect(model.modal == modal)
            #expect(model.modalOffset == 0)
            press(.down)
            #expect(model.modalOffset == 1)
            for blocked in [TerminalKey.tab, .character("x"), .character("S"), .character("P"), .character("s")] {
                press(blocked)
            }
            #expect(model.details)
            #expect(model.selectedID == selected)
            #expect(model.detailOffset == 1)
            #expect(model.sort == .queue)
            #expect(model.confirmation == nil)
            #expect(pending == nil)
            press(.escape)
            #expect(model.modal == nil)
            #expect(model.details)
            press(key)
            press(key)
            #expect(model.modal == nil)
        }
        press(.tab)
        #expect(!model.details)
        press(.character("x"))
        #expect(model.confirmation?.ids == Set([selected!]))
        press(.down)
        press(.tab)
        #expect(model.selectedID == selected)
        #expect(!model.details)
        press(.escape)
        press(.tab)
        #expect(model.details)
        #expect(model.selectedID == selected)
        #expect(model.detailOffset == 1)
        press(.escape)
        #expect(!model.details)
        press(.character("/"))
        press(.character("i"))
        #expect(model.filter == "i")
        #expect(model.modal == nil)
        press(.tab)
        #expect(!model.details && !model.editingFilter)
        press(.tab)
        #expect(model.details)
        #expect(model.filter == "i")
        press(.escape)
        #expect(!model.details)
        press(.escape)
        #expect(model.filter.isEmpty)
        press(.character("s"))
        #expect(model.sort == .name)
        press(.character("h"))
        #expect(model.showHistory)
        #expect(!model.details)
        press(.enter)
        #expect(!model.details)
        press(.character("h"))
        #expect(model.selectedID != nil)
    }

    @Test func cancellationExcludesNewArrivalsAndClearRevalidatesStartedWork() throws {
        let f = try OperatorFixture()
        let first = try f.submit("first")
        let second = try f.submit("second")
        let ids: Set<String> = [first.id, second.id]
        let later = try f.submit("later")
        try f.scheduler.transaction { state in
            state.tasks[0].state = .running
            state.tasks[0].startedAt = Date()
        }
        #expect(try f.queue.cancel(ids, onlyNeverStarted: true) == [second.id])
        #expect(!FileManager.default.fileExists(atPath: f.store.file(first.id, "cancel").path))
        #expect(!FileManager.default.fileExists(atPath: f.store.file(later.id, "cancel").path))
        #expect(try f.queue.cancel([first.id]) == [first.id])
        #expect(FileManager.default.fileExists(atPath: f.store.file(first.id, "cancel").path))
        #expect(!FileManager.default.fileExists(atPath: f.store.file(later.id, "cancel").path))
        f.service.release()
        #expect(throws: LatchError.self) { try f.queue.cancel([later.id]) }
    }

    @Test func overviewKeepsSelectedJobsVisibleAndFilterTextCannotTriggerCommands() throws {
        var model = DashboardModel(interval: 1)
        var snapshot = Self.snapshot()
        let template = try #require(snapshot.view.jobs.last)
        snapshot.view.jobs += (3...20).map { index in
            var job = template
            job.jobID = "job-\(index)"
            job.name = "Queued job \(index)"
            job.queuePosition = index
            return job
        }
        model.ingest(snapshot)
        var pending: DashboardAction?
        _ = OperatorDashboard.handle(.end, model: &model, pending: &pending)
        #expect(model.selectedID == "job-20")
        let screen = DashboardRenderer.render(&model, width: 79, height: 24)
        let selected = try #require(screen.cells.first { $0.contains { $0.style.selected } })
        #expect(selected.map(\.text).joined().contains("Queued job 20"))
        #expect(screen.plain.contains("19–20/20"))
        _ = OperatorDashboard.handle(.character("/"), model: &model, pending: &pending)
        for character in "SxP?iq+-" {
            #expect(!OperatorDashboard.handle(.character(character), model: &model, pending: &pending))
        }
        #expect(model.filter == "SxP?iq+-")
        #expect(model.confirmation == nil)
        #expect(model.modal == nil)
        #expect(model.interval == 1)
        #expect(pending == nil)
        _ = OperatorDashboard.handle(.escape, model: &model, pending: &pending)
        _ = OperatorDashboard.handle(.down, model: &model, pending: &pending)
        #expect(model.selected?.name == "Release benchmark")
        let selectedJob = DashboardRenderer.render(&model, width: 119, height: 40)
        #expect(selectedJob.plain.contains("Waiting for running work"))
        _ = OperatorDashboard.handle(.enter, model: &model, pending: &pending)
        #expect(model.details)
        #expect(DashboardRenderer.detailLines(model, width: 100).contains { $0.contains("Release benchmark") })
    }

    @Test func selectedCancellationTerminatesOnlyItsCLIWorkload() throws {
        let f = try OperatorFixture()
        let child = try f.fixture.launch(["run", "--shared", "--", "/bin/sleep", "30"])
        try f.fixture.waitUntilHeld(onWait: f.publishSensors)
        let id = try #require(try f.scheduler.snapshot().tasks.first?.id)
        let later = try f.submit("untouched")
        #expect(try f.queue.cancel([id]) == [id])
        #expect(try f.fixture.finish(child, onWait: f.publishSensors) == SIGTERM)
        #expect(!FileManager.default.fileExists(atPath: f.store.file(later.id, "cancel").path))
        #expect(try f.scheduler.snapshot().tasks.map(\.id) == [later.id])
    }

    @Test func dialogsScrollAllCapturedTargetsAndSensorsWorkWithoutJobs() throws {
        var model = DashboardModel(interval: 1)
        var snapshot = Self.snapshot()
        snapshot.view.jobs = []
        snapshot.view.tasks = []
        model.ingest(snapshot)
        model.modal = .sensors
        let screen = DashboardRenderer.render(&model, width: 119, height: 44)
        #expect(screen.plain.contains("QUIET LIMIT"))
        #expect(screen.plain.contains("RESERVATIONS"))
        #expect(screen.plain.contains("0.050 W"))
        #expect(screen.plain.contains("estimate alone does not block"))
        model.modalOffset = 1_000_000
        let scrolled = DashboardRenderer.render(&model, width: 79, height: 24)
        #expect(scrolled.plain.contains("Memory admission headroom"))
        #expect(scrolled.plain.contains("i / Esc close"))
        model.modal = nil
        model.confirmation = DashboardAction(kind: .stop, ids: ["captured"], names: (0..<60).map { "Job \($0)" })
        model.modalOffset = 1_000_000
        let dialog = DashboardRenderer.render(&model, width: 79, height: 24)
        #expect(dialog.plain.contains("Job 59"))
        #expect(dialog.plain.contains("y confirm"))
    }

    @Test func outputUsesRetainedStreamsWithoutTerminalEscapes() throws {
        let f = try OperatorFixture()
        let record = try f.submit("output")
        try f.store.publish(
            record.id,
            result: [
                "complete": true, "state": "completed", "succeeded": false, "exitCode": 1,
                "stdout": "hello\n\u{1B}]52;c;bad\u{7}", "stderr": "failure", "stdoutTruncated": true,
            ])
        let snapshot = try DashboardSnapshot(scheduler: f.scheduler)
        let lines = try DashboardWorker.output(id: record.id, snapshot: snapshot, scheduler: f.scheduler)
        #expect(lines.contains { $0.contains("TRUNCATED") })
        #expect(lines.contains("exitCode: 1"))
        var model = DashboardModel(interval: 1)
        model.showHistory = true
        model.ingest(snapshot)
        model.details = true
        model.outputID = record.id
        model.outputLines = lines
        let safe = DashboardRenderer.detailLines(model, width: 100).joined(separator: "\n")
        #expect(safe.contains("failure"))
        #expect(!safe.contains("\u{1B}"))
        #expect(!safe.contains("\u{7}"))
    }

    @Test func openDetailsFollowCompletionWithoutLosingContextOrScrollPosition() throws {
        let f = try OperatorFixture()
        try f.publishSensors()
        let finished = try f.submit("job being read", measurement: true)
        let next = try f.submit("next job")
        try f.scheduler.transaction { state in
            let index = state.tasks.firstIndex { $0.id == finished.id }!
            state.tasks[index].state = .running
            state.tasks[index].startedAt = Date()
        }
        var model = DashboardModel(interval: 1)
        model.ingest(try DashboardSnapshot(scheduler: f.scheduler))
        var pending: DashboardAction?
        _ = OperatorDashboard.handle(.enter, model: &model, pending: &pending)
        model.detailOffset = 3
        #expect(model.selectedID == finished.id)
        let before = DashboardRenderer.detailLines(model, width: 100)
        try f.store.publish(
            finished.id,
            result: [
                "complete": true, "state": "completed", "exitCode": 0,
                "stdout": "Final job output", "stderr": "", "terminationReason": "exit",
            ])
        let snapshot = try DashboardSnapshot(scheduler: f.scheduler)
        model.ingest(snapshot)
        model.outputID = finished.id
        model.outputLines = try DashboardWorker.output(id: finished.id, snapshot: snapshot, scheduler: f.scheduler)
        #expect(model.details)
        #expect(!model.showHistory)
        #expect(model.selectedID == finished.id)
        #expect(model.selected?.complete == true)
        #expect(model.selected?.state == "completed")
        #expect(model.jobs.map(\.jobID) == [next.id])
        let after = DashboardRenderer.detailLines(model, width: 100)
        for line in before
        where line.contains("Reservations:") || line.contains("Temperature limits:")
            || line.contains("/usr/bin/true") || line.contains("Directory:")
        {
            #expect(after.contains(line))
        }
        #expect(after.contains("Final job output"))
        #expect(after.contains("exitCode: 0"))
        #expect(after.contains("SAVED JOB REQUIREMENTS"))
        _ = DashboardRenderer.render(&model, width: 79, height: 24)
        #expect(model.detailOffset == 3)
        for key in [TerminalKey.character("x"), .character("P")] {
            _ = OperatorDashboard.handle(key, model: &model, pending: &pending)
            #expect(model.confirmation == nil)
            #expect(pending == nil)
        }
        _ = OperatorDashboard.handle(.escape, model: &model, pending: &pending)
        #expect(!model.details)
        #expect(model.retainedDetail == nil)
        #expect(model.selectedID == next.id)
        _ = OperatorDashboard.handle(.enter, model: &model, pending: &pending)
        #expect(model.retainedDetail?.job.jobID == next.id)
        #expect(!DashboardRenderer.detailLines(model, width: 100).contains("Final job output"))
    }

    @Test func terminalKeepsDetailsOpenWhenTheJobFinishes() throws {
        let f = try OperatorFixture()
        try f.publishSensors()
        let job = try f.submit("finishing while open")
        let terminal = try DashboardPTY(fixture: f.fixture)
        try terminal.waitFor("JOBS ·")
        try terminal.send("\r")
        try terminal.waitFor("JOB DETAILS")
        terminal.transcript = ""
        try f.store.publish(
            job.id,
            result: [
                "complete": true, "state": "completed", "exitCode": 0,
                "stdout": "FINAL OUTPUT STILL READABLE", "stderr": "",
            ])
        try terminal.waitFor("completed")
        try terminal.waitFor("FINAL OUTPUT STILL READABLE")
        #expect(!terminal.transcript.contains("This job left the current view"))
        terminal.transcript = ""
        try terminal.send("\t")
        try terminal.waitFor("No jobs in this view.")
        try terminal.send("q")
        #expect(try f.fixture.finish(terminal.child, onWait: terminal.drain) == 0)
    }

    @Test func responsiveLayoutsStayInsideTheTerminal() throws {
        for width in [1, 44, 45, 59, 79, 99, 119, 159] {
            for height in [1, 11, 12, 24, 34, 44] {
                for details in [false, true] {
                    var model = Self.populatedModel()
                    model.details = details
                    let screen = DashboardRenderer.render(&model, width: width, height: height)
                    #expect(screen.cells.count == height)
                    for row in screen.cells {
                        #expect(row.count == width)
                        #expect(row.map(\.text).joined().reduce(0) { $0 + TerminalText.width($1) } == width)
                    }
                    #expect(!screen.plain.contains("\u{1B}"))
                    if !details, width >= 45, height >= 12 {
                        #expect(screen.plain.contains("JOBS ·"))
                        #expect(screen.plain.contains("Swift build"))
                        if height >= 24 {
                            #expect(!screen.plain.contains("NEXT ADMISSION"))
                            #expect(screen.plain.contains("Release benchmark"))
                        }
                    }
                }
            }
        }
        var model = Self.populatedModel()
        let screen = DashboardRenderer.render(&model, width: 119, height: 40)
        #expect(screen.plain.contains("JOBS ·"))
        #expect(screen.plain.contains("CPU temperature"))
        #expect(screen.plain.contains("ANE activity"))
        #expect(!screen.plain.contains("Busiest core"))
        #expect(screen.plain.contains("Release benchmark"))
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let output = root.appendingPathComponent(".build/tui-preview")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try screen.plain.write(to: output.appendingPathComponent("overview.txt"), atomically: true, encoding: .utf8)
        try Self.renderPreview(screen, to: output.appendingPathComponent("overview.png"))
        try Self.renderPreview(
            DashboardRenderer.render(&model, width: 79, height: 24), to: output.appendingPathComponent("compact.png"))
        for name in ["details", "sensors", "help"] {
            model.details = name == "details"
            model.modal = name == "sensors" ? .sensors : name == "help" ? .help : nil
            model.modalOffset = 0
            let preview = DashboardRenderer.render(&model, width: 119, height: 40)
            try preview.plain.write(
                to: output.appendingPathComponent("\(name).txt"), atomically: true, encoding: .utf8)
            try Self.renderPreview(preview, to: output.appendingPathComponent("\(name).png"))
            try Self.renderPreview(
                DashboardRenderer.render(&model, width: 79, height: 24),
                to: output.appendingPathComponent("\(name)-compact.png"))
        }
    }

    @Test func nonTerminalFailureAndHelpDoNotOpenTheDashboard() throws {
        let f = try Fixture()
        let help = try f.launch(["tui", "--help"])
        #expect(try f.finish(help) == 0)
        #expect(!FileManager.default.fileExists(atPath: f.lockPath + ".queue"))
        let child = try f.launch(["tui"])
        #expect(try f.finish(child) == 64)
        #expect(child.errors.contains("interactive terminal"))
        #expect(!FileManager.default.fileExists(atPath: f.lockPath + ".queue"))
    }

    @Test(arguments: [false, true]) func terminalLifecycleRestoresSettings(signalExit: Bool) throws {
        let f = try OperatorFixture()
        try f.publishSensors()
        _ = try f.submit("PTY build")
        let terminal = try DashboardPTY(fixture: f.fixture)
        try terminal.waitFor("JOBS ·")
        var raw = termios()
        #expect(tcgetattr(terminal.slave, &raw) == 0)
        #expect(raw.c_lflag & UInt(ICANON) == 0)
        terminal.transcript = ""
        try terminal.send("i")
        try terminal.waitFor("SENSORS & ADMISSION")
        try terminal.send("\u{1B}[F")
        try terminal.waitFor("Memory admission headroom")
        terminal.transcript = ""
        try terminal.send("i")
        try terminal.waitFor("JOBS ·")
        try terminal.send("\u{1B}[200~Syq\u{1B}[201~")
        try terminal.send("\r")
        try terminal.waitFor("JOB DETAILS")
        terminal.transcript = ""
        try terminal.send("\t")
        try terminal.waitFor("JOBS ·")
        terminal.transcript = ""
        try terminal.send("\t")
        try terminal.waitFor("JOB DETAILS")
        #expect(
            !FileManager.default.fileExists(
                atPath: f.store.file(try #require(try f.store.records().first?.id), "cancel").path))
        if signalExit {
            #expect(kill(terminal.child.process.processIdentifier, SIGTERM) == 0)
        } else {
            try terminal.send("q")
        }
        #expect(try f.fixture.finish(terminal.child, onWait: terminal.drain) == 0)
        terminal.drain()
        var restored = termios()
        #expect(tcgetattr(terminal.slave, &restored) == 0)
        #expect(restored.c_lflag == terminal.original.c_lflag)
        #expect(restored.c_iflag == terminal.original.c_iflag)
        #expect(restored.c_oflag == terminal.original.c_oflag)
        #expect(terminal.transcript.contains("\u{1B}[?25h\u{1B}[?1049l"))
    }

    @Test func terminalRestoresLastIntervalAndSavesExplicitOverrides() throws {
        let f = try OperatorFixture()
        try f.publishSensors()
        let first = try DashboardPTY(fixture: f.fixture, interval: nil)
        try first.waitFor("refresh 1.0s")
        try first.send("-")
        try first.waitFor("refresh 2.0s")
        try first.waitFor("Refresh interval saved: 2.0s.")
        try first.send("q")
        #expect(try f.fixture.finish(first.child, onWait: first.drain) == 0)

        let second = try DashboardPTY(fixture: f.fixture, interval: nil)
        try second.waitFor("refresh 2.0s")
        try second.send("+")
        try second.waitFor("refresh 1.0s")
        try second.send("q")
        #expect(try f.fixture.finish(second.child, onWait: second.drain) == 0)

        let override = try DashboardPTY(fixture: f.fixture, interval: 3)
        try override.waitFor("refresh 3.0s")
        try override.send("q")
        #expect(try f.fixture.finish(override.child, onWait: override.drain) == 0)
        let restored = try DashboardPTY(fixture: f.fixture, interval: nil)
        try restored.waitFor("refresh 3.0s")
        try restored.send("q")
        #expect(try f.fixture.finish(restored.child, onWait: restored.drain) == 0)
    }

    @Test func terminalResizesAndSuspendsWithoutLosingState() throws {
        let f = try OperatorFixture()
        try f.publishSensors()
        let terminal = try DashboardPTY(fixture: f.fixture)
        try terminal.waitFor("JOBS ·")
        var size = winsize(ws_row: 10, ws_col: 40, ws_xpixel: 0, ws_ypixel: 0)
        #expect(ioctl(terminal.master, TIOCSWINSZ, &size) == 0)
        try terminal.waitFor("terminal too small")
        try terminal.send("\u{1A}")
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        var info = proc_bsdinfo()
        repeat {
            _ = proc_pidinfo(
                terminal.child.process.processIdentifier, PROC_PIDTBSDINFO, 0, &info,
                Int32(MemoryLayout<proc_bsdinfo>.size))
            if info.pbi_status == SSTOP { break }
            Thread.sleep(forTimeInterval: 0.01)
        } while ProcessInfo.processInfo.systemUptime < deadline
        #expect(info.pbi_status == SSTOP)
        var settings = termios()
        #expect(tcgetattr(terminal.slave, &settings) == 0)
        #expect(settings.c_lflag == terminal.original.c_lflag)
        size.ws_col = 120
        size.ws_row = 40
        #expect(ioctl(terminal.master, TIOCSWINSZ, &size) == 0)
        terminal.transcript = ""
        #expect(kill(terminal.child.process.processIdentifier, SIGCONT) == 0)
        try terminal.waitFor("JOBS ·")
        try terminal.send("q")
        #expect(try f.fixture.finish(terminal.child, onWait: terminal.drain) == 0)
    }

    @Test func terminalRemainsResponsiveWhileTheStateLockIsHeld() throws {
        let f = try OperatorFixture()
        let mutex = try FileLatch(path: f.scheduler.directory.appendingPathComponent("state.lock").path)
        try mutex.acquire(shared: false, timeout: 0)
        defer { mutex.release() }
        let terminal = try DashboardPTY(fixture: f.fixture)
        try terminal.waitFor("Connecting")
        try terminal.send("q")
        #expect(try f.fixture.finish(terminal.child, onWait: terminal.drain) == 0)
    }

    @Test func terminalOperatorActionsUseConfirmedCapturedJobs() throws {
        let f = try OperatorFixture()
        try f.publishSensors()
        let first = try f.submit("first")
        let second = try f.submit("second")
        let terminal = try DashboardPTY(fixture: f.fixture)
        try terminal.waitFor("JOBS ·")
        try terminal.send("\u{1B}[BP")
        try terminal.waitFor("Prioritize this job?")
        try terminal.send("y")
        try terminal.waitFor("Prioritized")
        #expect(try f.scheduler.snapshot().tasks.first?.id == second.id)
        try terminal.send("C")
        try terminal.waitFor("Clear 2 never-started jobs?")
        let later = try f.submit("arrived during confirmation")
        try terminal.send("y")
        try terminal.waitFor("Cancellation requested for 2 job(s)")
        for id in [first.id, second.id] {
            #expect(FileManager.default.fileExists(atPath: f.store.file(id, "cancel").path))
        }
        #expect(!FileManager.default.fileExists(atPath: f.store.file(later.id, "cancel").path))
        try terminal.send("q")
        #expect(try f.fixture.finish(terminal.child, onWait: terminal.drain) == 0)
    }

    private static func snapshot() -> DashboardSnapshot {
        let sensors = SensorSnapshot(
            sampledAt: Date(), uptime: 100, cpuCores: 18, cpuActive: 0.12, busiestCore: 0.46,
            gpuActive: 0.28, aneWatts: 0.1, memoryAvailableMiB: 90000, memoryTotalMiB: 131072,
            memoryPressure: "normal", thermalState: "nominal", diskBytesPerSecond: 2_000_000, unavailable: [],
            cpuTemperature: 46, gpuTemperature: 41, aneActivity: .init(fraction: 0.25, source: .powerFloor),
            cpuWatts: 12.3, gpuWatts: 4.5)
        let first = ScheduledTask(
            id: "11111111-1111-4111-8111-111111111111", name: "Swift build", pid: 100,
            arguments: ["/usr/bin/swift", "build"], requirements: TaskRequirements(mode: .batch), state: .running,
            queuedUptime: 50, startedAt: Date().addingTimeInterval(-30))
        let second = ScheduledTask(
            id: "22222222-2222-4222-8222-222222222222", name: "Release benchmark", pid: 0,
            arguments: ["/work/benchmark"],
            requirements: TaskRequirements(measurement: true, temperatureGuard: TemperatureGuard()), queuedUptime: 60)
        let state = SchedulerState(tasks: [first, second], sensors: sensors)
        var view = SchedulerView(
            state: state,
            service: .init(running: true, pid: 42, path: "/queue", serviceRevision: BuildIdentity.serviceRevision),
            processLatch: "shared", now: 100)
        view.samplingPaused = false
        view.samplingPausedReason = nil
        return DashboardSnapshot(view: view)
    }

    private static func populatedModel() -> DashboardModel {
        var model = DashboardModel(interval: 1)
        var snapshot = snapshot()
        for index in 0..<80 {
            snapshot.view.sensors?.uptime = 100 + Double(index)
            snapshot.view.sensors?.cpuActive = 0.2 + 0.16 * sin(Double(index) / 8)
            snapshot.view.sensors?.gpuActive = 0.45 + 0.3 * sin(Double(index) / 12)
            snapshot.view.sensors?.aneActivity?.fraction = index % 20 < 10 ? 0.15 : 0.6
            model.ingest(snapshot)
        }
        return model
    }

    @Test func filledBarsKeepGapsZeroesAndCapturedTones() {
        let values: [Double?] = [0, 0, 100, nil, 50, 50]
        let samples = values.map { value in
            DashboardSample(date: Date(), values: value.map { [.ane: $0] } ?? [:], tones: [.ane: .warning])
        }
        let plot = DashboardChart.bars(samples: samples, metric: .ane, width: 8, height: 4)
        #expect(plot.cells.allSatisfy { $0[0].text == " " && $0[1].text == " " && $0[5].text == " " })
        #expect(plot.cells[3][2].text == "·")
        #expect(plot.cells.allSatisfy { $0[4].text == "█" })
        #expect(plot.cells[0][6].text == " ")
        #expect(plot.cells[2][6].text == "█")
        #expect(plot.cells[3][6].text == "█")
        #expect(plot.cells.flatMap { $0 }.filter { $0.text != " " }.allSatisfy { $0.style.tone == .warning })
        let empty = DashboardChart.bars(samples: [], metric: .ane, width: 8, height: 4)
        #expect(empty.cells.flatMap { $0 }.allSatisfy { $0.text == " " })
    }

    @Test func chartLabelsNeverPresentStaleZeroAsCurrentGPUActivity() {
        var model = DashboardModel(interval: 1)
        var snapshot = Self.snapshot()
        snapshot.view.sensors?.gpuActive = 0
        snapshot.view.sensorAgeSeconds = 3
        snapshot.view.sensorsFresh = false
        model.ingest(snapshot)
        let stale = DashboardRenderer.render(&model, width: 119, height: 44)
        #expect(stale.plain.contains("Stale · last 0.0%"))
        #expect(!stale.plain.contains("0.0%  normal"))
        let compact = DashboardRenderer.render(&model, width: 79, height: 32)
        let gpu = compact.plain.split(separator: "\n").first { $0.contains("GPU activity") }
        #expect(gpu?.contains("stale") == true)
        #expect(gpu?.contains("0.0%") == false)
        snapshot.view.sensors?.uptime += 100
        snapshot.view.sensors?.gpuActive = 0.7
        snapshot.view.sensorAgeSeconds = 0
        snapshot.view.sensorsFresh = true
        model.ingest(snapshot)
        let live = DashboardRenderer.render(&model, width: 119, height: 44)
        #expect(live.plain.contains("70.0%  normal"))
        #expect(model.samples.last?.values[.gpu] == 70)
    }

    @Test func overviewShowsCPUGPUAndANEPowerInOrder() throws {
        var model = DashboardModel(interval: 1)
        var snapshot = Self.snapshot()
        snapshot.view.sensors?.cpuWatts = 12.3
        snapshot.view.sensors?.gpuWatts = 4.5
        model.ingest(snapshot)
        for (width, height) in [(45, 24), (79, 32), (119, 34), (119, 44)] {
            let text = DashboardRenderer.render(&model, width: width, height: height).plain
            let lines = text.split(separator: "\n")
            let reservationIndex = try #require(lines.firstIndex { $0.contains("Reservations") })
            let powerIndex = try #require(lines.firstIndex { $0.contains("Power  CPU") })
            let memoryIndex = try #require(lines.firstIndex { $0.contains("Available RAM") })
            #expect(powerIndex == reservationIndex + 1)
            #expect(memoryIndex == powerIndex + 1)
            let power = lines[powerIndex]
            #expect(power.contains("CPU 12.3 W · GPU 4.5 W · ANE 0.1 W"))
        }
        snapshot.view.sensors?.cpuWatts = nil
        snapshot.view.sensors?.gpuWatts = 0
        model.ingest(snapshot)
        #expect(DashboardRenderer.render(&model, width: 79, height: 32).plain.contains("CPU — · GPU 0.0 W"))
        snapshot.view.sensorAgeSeconds = 3
        model.ingest(snapshot)
        #expect(DashboardRenderer.render(&model, width: 119, height: 44).plain.contains("Last power"))
    }

    @Test func idleSamplesExpirePromptlyButSlowDisplayRefreshDoesNotFabricateGaps() {
        var model = DashboardModel(interval: 60)
        var snapshot = Self.snapshot()
        snapshot.view.jobs = []
        model.ingest(snapshot)
        snapshot.view.sensors?.uptime += 60
        model.ingest(snapshot)
        #expect(model.samples.count == 2)
        #expect(model.samples.allSatisfy { !$0.values.isEmpty })
        snapshot.view.sensorAgeSeconds = 3
        model.ingest(snapshot)
        #expect(model.sensorHoldReason == "stale")
        #expect(model.alerts.contains { $0.id == "stale" })
        #expect(model.samples.last?.values.isEmpty == true)
    }

    @Test func detailsOverlayLeavesOverviewVisibleAroundItsEdges() {
        var model = Self.populatedModel()
        let overview = DashboardRenderer.render(&model, width: 119, height: 40)
        model.details = true
        let overlay = DashboardRenderer.render(&model, width: 119, height: 40)
        #expect(overlay.plain.contains("JOB DETAILS · Tab / Esc close"))
        #expect(overlay.plain.contains("Swift build"))
        #expect(overlay.cells[0] == overview.cells[0])
        #expect(overlay.cells[2] == overview.cells[2])
        for row in 3..<37 {
            #expect(overlay.cells[row][1] == overview.cells[row][1])
            #expect(overlay.cells[row][117] == overview.cells[row][117])
        }
        model.details = false
        #expect(DashboardRenderer.render(&model, width: 119, height: 40) == overview)
    }

    private static func renderPreview(_ screen: TerminalScreen, to url: URL) throws {
        let cellWidth = 9
        let cellHeight = 20
        let width = screen.width * cellWidth + 24
        let height = screen.height * cellHeight + 24
        let context = try #require(
            CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let background = CGColor(red: 0.055, green: 0.071, blue: 0.09, alpha: 1)
        context.setFillColor(background)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let font = CTFontCreateWithName("Menlo" as CFString, 14, nil)
        let bold = CTFontCreateWithName("Menlo-Bold" as CFString, 14, nil)
        func color(_ tone: DashboardTone) -> CGColor {
            let rgb: (CGFloat, CGFloat, CGFloat) =
                switch tone {
                case .normal: (0.82, 0.82, 0.82)
                case .muted: (0.5, 0.5, 0.5)
                case .accent: (0.37, 0.84, 1)
                case .good: (0.53, 0.84, 0.53)
                case .warning: (1, 0.84, 0.37)
                case .critical: (1, 0.37, 0.37)
                }
            return CGColor(red: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
        }
        for (rowIndex, row) in screen.cells.enumerated() {
            for (column, cell) in row.enumerated() where !cell.text.isEmpty {
                let x = 12 + column * cellWidth
                let y = height - 12 - (rowIndex + 1) * cellHeight
                if cell.style.selected {
                    context.setFillColor(color(cell.style.tone))
                    context.fill(
                        CGRect(x: x, y: y, width: cellWidth * TerminalText.width(cell.text.first!), height: cellHeight))
                }
                let attributes: [CFString: Any] = [
                    kCTFontAttributeName: cell.style.bold ? bold : font,
                    kCTForegroundColorAttributeName: cell.style.selected ? background : color(cell.style.tone),
                ]
                let text = try #require(
                    CFAttributedStringCreate(nil, cell.text as CFString, attributes as CFDictionary))
                context.textPosition = CGPoint(x: x, y: y + 4)
                CTLineDraw(CTLineCreateWithAttributedString(text), context)
            }
        }
        let image = try #require(context.makeImage())
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
    }
}

private final class DashboardPTY {
    let master: Int32
    let slave: Int32
    let child = Child()
    var original = termios()
    var transcript = ""

    init(fixture: Fixture, interval: Double? = 0.5) throws {
        var master: Int32 = -1
        var slave: Int32 = -1
        var size = winsize(ws_row: 40, ws_col: 120, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&master, &slave, nil, nil, &size) == 0 else { throw LatchError("openpty failed") }
        self.master = master
        self.slave = slave
        #expect(tcgetattr(slave, &original) == 0)
        #expect(fcntl(master, F_SETFL, O_NONBLOCK) == 0)
        child.process.executableURL = fixture.executable
        child.process.arguments = ["tui", "--file", fixture.lockPath]
        if let interval { child.process.arguments! += ["--interval", String(interval)] }
        child.process.environment = ProcessInfo.processInfo.environment.merging([
            "TERM": "xterm-256color", "NO_COLOR": "1", "XDG_CONFIG_HOME": fixture.directory.path,
        ]) { _, new in new }
        let terminal = FileHandle(fileDescriptor: slave, closeOnDealloc: false)
        child.process.standardInput = terminal
        child.process.standardOutput = terminal
        child.process.standardError = terminal
        try child.process.run()
        fixture.children.append(child)
    }

    deinit {
        if child.process.isRunning {
            kill(child.process.processIdentifier, SIGKILL)
            child.process.waitUntilExit()
        }
        close(master)
        close(slave)
    }

    func send(_ text: String) throws {
        let data = Data(text.utf8)
        let count = data.withUnsafeBytes { Darwin.write(master, $0.baseAddress, $0.count) }
        guard count == data.count else { throw LatchError("PTY input failed") }
    }

    func drain() {
        var bytes = [UInt8](repeating: 0, count: 16384)
        while true {
            let count = Darwin.read(master, &bytes, bytes.count)
            guard count > 0 else { break }
            transcript += String(decoding: bytes.prefix(count), as: UTF8.self)
        }
    }

    func waitFor(_ text: String) throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        repeat {
            drain()
            if transcript.contains(text) { return }
            Thread.sleep(forTimeInterval: 0.01)
        } while ProcessInfo.processInfo.systemUptime < deadline
        throw LatchError("PTY did not display \(text): \(transcript)")
    }
}
