import AppKit
import SwiftUI

/// Native editor for Amphetamine-compatible ordered Triggers. The editor keeps
/// values as a small draft model until Save, so malformed user input never
/// reaches the evaluator or the persisted store.
struct TriggerSettingsSection: View {
    @Bindable var store: TriggerStore
    @Bindable var coordinator: TriggerCoordinator
    let closedDisplaySupported: Bool
    @State private var editingTrigger: AwakeTrigger?
    @State private var isCreating = false
    @State private var errorMessage: String?

    var body: some View {
        Section {
            Toggle(
                L("Enable Triggers"),
                isOn: Binding(
                    get: { store.isEnabled },
                    set: { store.setEnabled($0) }
                )
            )

            if store.triggers.isEmpty {
                Text(L("No Triggers"))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(store.triggers.enumerated()), id: \.element.id) { index, trigger in
                    triggerRow(trigger, index: index)
                }
            }

            HStack {
                Button {
                    isCreating = true
                    editingTrigger = AwakeTrigger(
                        name: L("New Trigger"),
                        criteria: [.wifiNetwork("")]
                    )
                } label: {
                    Label(L("Add Trigger"), systemImage: "plus")
                }
                .buttonStyle(.borderless)

                Spacer()
                if !store.triggers.isEmpty {
                    Text(String(format: L("Trigger Count"), store.triggers.count))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if let loadError = store.loadErrorMessage {
                Label(loadError, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
            if let errorMessage {
                HStack(spacing: 6) {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    Spacer()
                    Button {
                        self.errorMessage = nil
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.borderless)
                }
                .font(.footnote)
                .foregroundStyle(.orange)
            }
        } header: {
            Text(L("Triggers"))
        } footer: {
            Text(L("Triggers Help"))
        }
        .sheet(item: $editingTrigger) { trigger in
            TriggerEditorView(
                trigger: trigger,
                closedDisplaySupported: closedDisplaySupported,
                onSave: { candidate in
                    do {
                        if isCreating {
                            _ = try store.add(candidate)
                        } else {
                            try store.update(candidate)
                        }
                        errorMessage = nil
                        editingTrigger = nil
                    } catch {
                        errorMessage = localizedTriggerError(error)
                    }
                },
                onCancel: {
                    editingTrigger = nil
                }
            )
        }
    }

    private func triggerRow(_ trigger: AwakeTrigger, index: Int) -> some View {
        HStack(spacing: 8) {
            Toggle(
                "",
                isOn: Binding(
                    get: { trigger.isEnabled },
                    set: { enabled in
                        do {
                            try store.setTriggerEnabled(enabled, id: trigger.id)
                        } catch {
                            errorMessage = localizedTriggerError(error)
                        }
                    }
                )
            )
            .labelsHidden()
            .toggleStyle(.switch)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(trigger.name)
                        .lineLimit(1)
                    if coordinator.activeTriggerID == trigger.id {
                        Image(systemName: "bolt.fill")
                            .foregroundStyle(.green)
                            .help(L("Trigger Active"))
                    }
                }
                Text(trigger.criteria.map(\.kind.displayName).joined(separator: " + "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)
            Button {
                isCreating = false
                editingTrigger = trigger
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            .help(L("Edit Trigger"))
            .accessibilityLabel(L("Edit Trigger"))

            Menu {
                Button {
                    moveTrigger(trigger, offset: -1)
                } label: {
                    Label(L("Move Trigger Up"), systemImage: "chevron.up")
                }
                .disabled(index == 0)
                Button {
                    moveTrigger(trigger, offset: 1)
                } label: {
                    Label(L("Move Trigger Down"), systemImage: "chevron.down")
                }
                .disabled(index == store.triggers.count - 1)
                Divider()
                Button(role: .destructive) {
                    removeTrigger(trigger)
                } label: {
                    Label(L("Delete Trigger"), systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .help(L("Trigger Actions"))
        }
    }

    private func moveTrigger(_ trigger: AwakeTrigger, offset: Int) {
        guard let source = store.triggers.firstIndex(where: { $0.id == trigger.id }) else { return }
        let destination = source + offset
        guard store.triggers.indices.contains(destination) else { return }
        do {
            // TriggerStore's destination is an insertion index. Moving down
            // therefore inserts after the target's current index.
            try store.move(
                from: source,
                to: destination + (offset > 0 ? 1 : 0)
            )
        } catch {
            errorMessage = localizedTriggerError(error)
        }
    }

    private func removeTrigger(_ trigger: AwakeTrigger) {
        do {
            try store.remove(id: trigger.id)
        } catch {
            errorMessage = localizedTriggerError(error)
        }
    }

    private func localizedTriggerError(_ error: Error) -> String {
        if let localized = error as? LocalizedError,
           let description = localized.errorDescription {
            return description
        }
        return L("Trigger Operation Failed")
    }
}

private struct TriggerEditorView: View {
    @Environment(\.dismiss) private var dismiss
    let originalTrigger: AwakeTrigger
    let closedDisplaySupported: Bool
    let onSave: (AwakeTrigger) -> Void
    let onCancel: () -> Void
    @State private var draft: TriggerDraft
    @State private var errorMessage: String?
    @State private var snapshot = TriggerSnapshot()
    @State private var snapshotProvider: LocalTriggerSnapshotProvider
    @State private var wifiPermission: WiFiLocationPermissionController

    init(
        trigger: AwakeTrigger,
        closedDisplaySupported: Bool,
        onSave: @escaping (AwakeTrigger) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.originalTrigger = trigger
        self.closedDisplaySupported = closedDisplaySupported
        self.onSave = onSave
        self.onCancel = onCancel
        _draft = State(initialValue: TriggerDraft(trigger: trigger))
        _snapshotProvider = State(initialValue: LocalTriggerSnapshotProvider())
        _wifiPermission = State(initialValue: WiFiLocationPermissionController())
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section(L("Trigger Details")) {
                    TextField(L("Trigger Name"), text: $draft.name)
                    Toggle(L("Trigger Enabled"), isOn: $draft.isEnabled)
                }

                Section {
                    if draft.criteria.contains(where: { $0.kind == .wifiNetwork }),
                       wifiPermission.state != .authorized {
                        WiFiPermissionNotice(controller: wifiPermission)
                    }
                    if draft.criteria.isEmpty {
                        Text(L("Trigger Requires Criterion"))
                            .foregroundStyle(.secondary)
                    }
                    ForEach($draft.criteria) { $criterion in
                        CriterionEditor(draft: $criterion, snapshot: snapshot) {
                            draft.criteria.removeAll { $0.id == criterion.id }
                        }
                    }

                    Menu {
                        ForEach(TriggerCriterion.Kind.allCases, id: \.self) { kind in
                            Button(kind.displayName) {
                                draft.criteria.append(CriterionDraft(kind: kind))
                                if kind == .wifiNetwork {
                                    wifiPermission.requestIfNeeded()
                                }
                                refreshSnapshot()
                            }
                            .disabled(draft.criteria.contains { $0.kind == kind })
                        }
                    } label: {
                        Label(L("Add Criterion"), systemImage: "plus.circle")
                    }
                    Button {
                        refreshSnapshot()
                    } label: {
                        Label(L("Refresh Trigger Values"), systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                } header: {
                    Text(L("Trigger Criteria"))
                } footer: {
                    Text(L("Trigger Criteria Help"))
                }

                Section(L("Trigger Session Options")) {
                    Toggle(L("Allow Display Sleep"), isOn: $draft.allowsDisplaySleep)
                    Toggle(
                        L("Allow Closed Display Sleep"),
                        isOn: $draft.allowsClosedDisplaySleep
                    )
                    .disabled(!closedDisplaySupported)
                    if !closedDisplaySupported {
                        Text(L("Closed Display Unsupported"))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Picker(L("Screen Saver"), selection: $draft.screenSaverMode) {
                        Text(L("Prevent Screen Saver")).tag(ScreenSaverDraftMode.prevent)
                        Text(L("Allow Screen Saver After Delay")).tag(ScreenSaverDraftMode.allowAfter)
                    }
                    if draft.screenSaverMode == .allowAfter {
                        HStack {
                            Text(L("Screen Saver Delay"))
                            Spacer()
                            TextField(L("Minutes"), text: $draft.screenSaverDelayText)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 72)
                            Text(L("Minutes"))
                                .foregroundStyle(.secondary)
                        }
                        TextField(
                            L("Screen Saver Exceptions"),
                            text: $draft.screenSaverExceptionsText
                        )
                        Text(L("Trigger Screen Saver Exceptions Help"))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Button(L("Cancel")) {
                    onCancel()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
                Button(L("Save")) {
                    save()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
            .padding(12)
        }
        .frame(width: 650, height: 620)
        .task { refreshSnapshot() }
        .onChange(of: wifiPermission.state) {
            if wifiPermission.state == .authorized { refreshSnapshot() }
        }
    }

    private func save() {
        do {
            let trigger = try draft.makeTrigger(id: originalTrigger.id)
            onSave(trigger)
            dismiss()
        } catch {
            if let localized = error as? LocalizedError,
               let description = localized.errorDescription {
                errorMessage = description
            } else {
                errorMessage = L("Trigger Operation Failed")
            }
        }
    }

    private func refreshSnapshot() {
        snapshot = snapshotProvider.snapshot(
            requiredCriteria: Set(draft.criteria.map(\.kind))
        )
    }
}

private struct WiFiPermissionNotice: View {
    @Bindable var controller: WiFiLocationPermissionController

    var body: some View {
        HStack(spacing: 8) {
            Label(L("Wi-Fi Trigger Needs Location"), systemImage: "location")
                .foregroundStyle(.orange)
            Spacer()
            switch controller.state {
            case .notDetermined:
                Button(L("Allow Location")) { controller.requestIfNeeded() }
            case .denied, .restricted:
                Button(L("Open Location Settings")) { controller.openSettings() }
            case .authorized:
                EmptyView()
            }
        }
        .font(.footnote)
    }
}

private struct CriterionEditor: View {
    @Binding var draft: CriterionDraft
    let snapshot: TriggerSnapshot
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            DisclosureGroup {
                criterionFields
            } label: {
                HStack {
                    Image(systemName: draft.kind.symbolName)
                    Text(draft.kind.displayName)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help(L("Remove Criterion"))
            .accessibilityLabel(L("Remove Criterion"))
        }
    }

    @ViewBuilder
    private var criterionFields: some View {
        currentValueControl
        switch draft.kind {
        case .schedule:
            scheduleFields
        case .systemIdleTime:
            thresholdFields(valueLabel: L("Idle Minutes"), allowsZero: false)
        case .dnsServer:
            TextField(L("DNS Server Addresses"), text: $draft.addressesText)
            Text(L("Enter comma separated IPv4 or IPv6 addresses."))
                .font(.footnote)
                .foregroundStyle(.secondary)
        case .wifiNetwork:
            TextField(L("Wi-Fi Network Name"), text: $draft.identifierText)
        case .ipAddress:
            ipAddressFields
        case .ciscoAnyConnectVPN:
            TextField(L("VPN Service Name"), text: $draft.identifierText)
        case .volume:
            TextField(L("Volume Identifier"), text: $draft.identifierText)
            Text(L("Use the mounted volume UUID or path shown by the current snapshot."))
                .font(.footnote)
                .foregroundStyle(.secondary)
        case .application:
            TextField(L("Application or Process Identifier"), text: $draft.identifierText)
            Toggle(L("Require Application Frontmost"), isOn: $draft.requiresFrontmost)
        case .cpuUtilization:
            thresholdFields(valueLabel: L("CPU Percentage"), allowsZero: true)
            Text(L("The percentage is sampled over a short rolling interval."))
                .font(.footnote)
                .foregroundStyle(.secondary)
        case .displays:
            displayFields
        case .bluetoothDevice:
            TextField(L("Bluetooth Device Identifier"), text: $draft.identifierText)
            Text(L("Use the paired device address from the current snapshot."))
                .font(.footnote)
                .foregroundStyle(.secondary)
        case .audioOutput:
            audioFields
        case .usbDevice:
            TextField(L("USB Device Identifier"), text: $draft.identifierText)
            Text(L("Use the vendor:product:serial identifier from the current snapshot."))
                .font(.footnote)
                .foregroundStyle(.secondary)
        case .batteryAndPowerAdapter:
            batteryFields
        }
    }

    @ViewBuilder
    private var currentValueControl: some View {
        switch draft.kind {
        case .schedule:
            Button(L("Use Current Trigger Value")) {
                let calendar = Calendar.current
                let now = Date()
                if let weekday = TriggerWeekday(rawValue: calendar.component(.weekday, from: now)) {
                    draft.weekdays = [weekday]
                }
                let components = calendar.dateComponents([.hour, .minute], from: now)
                let minute = (components.hour ?? 0) * 60 + (components.minute ?? 0)
                draft.startMinute = minute
                draft.endMinute = (minute + 60) % 1_440
            }
            .buttonStyle(.borderless)
        case .systemIdleTime:
            if let idle = snapshot.systemIdleTime {
                Button(L("Use Current Trigger Value")) {
                    draft.thresholdValueText = String(max(1, Int((idle / 60).rounded())))
                }
                .buttonStyle(.borderless)
            }
        case .dnsServer:
            currentValueMenu(snapshot.dnsServers.map(\.description).sorted()) { value in
                draft.addressesText = value
            }
        case .wifiNetwork:
            if let ssid = snapshot.wifiSSID {
                currentValueButton(ssid) { draft.identifierText = ssid }
            }
        case .ipAddress:
            currentValueMenu(snapshot.ipAddresses.map(\.description).sorted()) { value in
                draft.ipRangeMode = false
                draft.ipStartText = value
            }
        case .ciscoAnyConnectVPN:
            currentValueMenu(snapshot.activeVPNServices.sorted()) { value in
                draft.identifierText = value
            }
        case .volume:
            currentValueMenu(snapshot.mountedVolumeIdentifiers.sorted()) { value in
                draft.identifierText = value
            }
        case .application:
            currentValueMenu(snapshot.runningApplicationIdentifiers.sorted()) { value in
                draft.identifierText = value
            }
        case .cpuUtilization:
            if let cpu = snapshot.cpuUtilizationPercentage {
                Button(L("Use Current Trigger Value")) {
                    draft.thresholdValueText = String((cpu * 10).rounded() / 10)
                }
                .buttonStyle(.borderless)
            }
        case .displays:
            if let count = snapshot.displayCount {
                Button(L("Use Current Trigger Value")) {
                    draft.displayMirrored = false
                    draft.displayCountText = String(count)
                }
                .buttonStyle(.borderless)
            }
        case .bluetoothDevice:
            currentValueMenu(snapshot.connectedBluetoothIdentifiers.sorted()) { value in
                draft.identifierText = value
            }
        case .audioOutput:
            if let identifier = snapshot.audioOutputIdentifier {
                currentValueButton(identifier) {
                    draft.audioKind = .device
                    draft.identifierText = identifier
                }
            }
        case .usbDevice:
            currentValueMenu(snapshot.connectedUSBIdentifiers.sorted()) { value in
                draft.identifierText = value
            }
        case .batteryAndPowerAdapter:
            if snapshot.batteryPercentage != nil || snapshot.powerAdapterConnected != nil {
                Button(L("Use Current Trigger Value")) {
                    if let battery = snapshot.batteryPercentage {
                        draft.batteryMinimumEnabled = true
                        draft.batteryMinimumText = String(Int(battery.rounded()))
                    }
                    if let connected = snapshot.powerAdapterConnected {
                        draft.adapterRequirementEnabled = true
                        draft.adapterRequirement = connected ? .connected : .disconnected
                    }
                }
                .buttonStyle(.borderless)
            }
        }
    }

    @ViewBuilder
    private func currentValueMenu(
        _ values: [String],
        onSelect: @escaping (String) -> Void
    ) -> some View {
        if !values.isEmpty {
            Menu(L("Use Current Trigger Value")) {
                ForEach(values, id: \.self) { value in
                    Button(value) { onSelect(value) }
                }
            }
            .menuStyle(.button)
        }
    }

    private func currentValueButton(
        _ value: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(L("Use Current Trigger Value"), systemImage: "scope")
        }
        .buttonStyle(.borderless)
        .help(value)
    }

    private var scheduleFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("Weekdays"))
                .font(.subheadline)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 6) {
                ForEach(TriggerWeekday.allCases, id: \.self) { day in
                    Button {
                        if draft.weekdays.contains(day) {
                            draft.weekdays.remove(day)
                        } else {
                            draft.weekdays.insert(day)
                        }
                    } label: {
                        Text(day.shortDisplayName)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(draft.weekdays.contains(day) ? .accentColor : .secondary)
                }
            }
            DatePicker(L("Starts"), selection: startDate, displayedComponents: .hourAndMinute)
            DatePicker(L("Ends"), selection: endDate, displayedComponents: .hourAndMinute)
            Text(L("An end time earlier than the start time continues across midnight."))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func thresholdFields(valueLabel: String, allowsZero: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker(L("Comparison"), selection: $draft.thresholdComparison) {
                Text(L("Less Than")).tag(ThresholdOperator.lessThan)
                Text(L("Greater Than")).tag(ThresholdOperator.greaterThan)
            }
            TextField(valueLabel, text: $draft.thresholdValueText)
                .textFieldStyle(.roundedBorder)
            if !allowsZero {
                Text(L("Use a value greater than zero."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var ipAddressFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker(L("IP Address Match"), selection: $draft.ipRangeMode) {
                Text(L("Exact Address")).tag(false)
                Text(L("Inclusive Range")).tag(true)
            }
            TextField(L("IP Address"), text: $draft.ipStartText)
            if draft.ipRangeMode {
                TextField(L("Range End"), text: $draft.ipEndText)
            }
        }
    }

    private var displayFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker(L("Display Requirement"), selection: $draft.displayMirrored) {
                Text(L("Display Count")).tag(false)
                Text(L("Main Display Mirrored")).tag(true)
            }
            if !draft.displayMirrored {
                Picker(L("Comparison"), selection: $draft.displayComparison) {
                    Text(L("Less Than")).tag(CountOperator.lessThan)
                    Text(L("Equal")).tag(CountOperator.equal)
                    Text(L("Greater Than")).tag(CountOperator.greaterThan)
                }
                TextField(L("Display Count"), text: $draft.displayCountText)
                Toggle(L("Ignore Built-In Display"), isOn: $draft.ignoresBuiltInDisplay)
            }
        }
    }

    private var audioFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker(L("Audio Output"), selection: $draft.audioKind) {
                Text(L("Specific Device")).tag(AudioDraftKind.device)
                Text(L("Built-In Output")).tag(AudioDraftKind.builtInOutput)
                Text(L("Built-In Speakers")).tag(AudioDraftKind.builtInSpeakers)
                Text(L("Wired Headphones")).tag(AudioDraftKind.wiredHeadphones)
            }
            if draft.audioKind == .device {
                TextField(L("Audio Device Identifier"), text: $draft.identifierText)
            }
        }
    }

    private var batteryFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(L("Require Minimum Battery"), isOn: $draft.batteryMinimumEnabled)
            if draft.batteryMinimumEnabled {
                TextField(L("Minimum Battery Percentage"), text: $draft.batteryMinimumText)
            }
            Toggle(L("Require Power Adapter"), isOn: $draft.adapterRequirementEnabled)
            if draft.adapterRequirementEnabled {
                Picker(L("Power Adapter"), selection: $draft.adapterRequirement) {
                    Text(L("Connected")).tag(PowerAdapterRequirement.connected)
                    Text(L("Disconnected")).tag(PowerAdapterRequirement.disconnected)
                }
            }
            if draft.batteryMinimumEnabled && draft.adapterRequirementEnabled {
                Picker(L("Combine Requirements"), selection: $draft.batteryCombination) {
                    Text(L("All Requirements (AND)")).tag(LogicalOperator.and)
                    Text(L("Any Requirement (OR)")).tag(LogicalOperator.or)
                }
            }
        }
    }

    private var startDate: Binding<Date> {
        Binding(
            get: { dateForMinute(draft.startMinute) },
            set: { draft.startMinute = minute(from: $0) }
        )
    }

    private var endDate: Binding<Date> {
        Binding(
            get: { dateForMinute(draft.endMinute) },
            set: { draft.endMinute = minute(from: $0) }
        )
    }

    private func dateForMinute(_ value: Int) -> Date {
        Calendar.current.date(
            bySettingHour: value / 60,
            minute: value % 60,
            second: 0,
            of: Date()
        ) ?? Date()
    }

    private func minute(from date: Date) -> Int {
        let components = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (components.hour ?? 0) * 60 + (components.minute ?? 0)
    }
}

private enum ScreenSaverDraftMode: String, CaseIterable {
    case prevent
    case allowAfter
}

private enum IPDraftError: Error, LocalizedError {
    case invalid

    var errorDescription: String? { L("Trigger Invalid Criterion") }
}

private enum AudioDraftKind: String, CaseIterable {
    case device
    case builtInOutput
    case builtInSpeakers
    case wiredHeadphones
}

private struct CriterionDraft: Identifiable, Equatable {
    let id: UUID
    var kind: TriggerCriterion.Kind
    var weekdays: Set<TriggerWeekday> = Set(TriggerWeekday.allCases)
    var startMinute = 9 * 60
    var endMinute = 17 * 60
    var thresholdComparison: ThresholdOperator = .greaterThan
    var thresholdValueText = "10"
    var addressesText = ""
    var identifierText = ""
    var requiresFrontmost = false
    var ipRangeMode = false
    var ipStartText = ""
    var ipEndText = ""
    var displayMirrored = false
    var displayComparison: CountOperator = .equal
    var displayCountText = "1"
    var ignoresBuiltInDisplay = false
    var audioKind: AudioDraftKind = .device
    var batteryMinimumEnabled = false
    var batteryMinimumText = "50"
    var adapterRequirementEnabled = false
    var adapterRequirement: PowerAdapterRequirement = .connected
    var batteryCombination: LogicalOperator = .and

    init(kind: TriggerCriterion.Kind) {
        self.id = UUID()
        self.kind = kind
    }

    init(criterion: TriggerCriterion) {
        self.id = UUID()
        self.kind = criterion.kind
        switch criterion {
        case let .schedule(value):
            weekdays = value.weekdays
            startMinute = value.startMinute
            endMinute = value.endMinute
        case let .systemIdleTime(value), let .cpuUtilization(value):
            thresholdComparison = value.comparison
            thresholdValueText = String(value.value)
        case let .dnsServer(addresses):
            addressesText = addresses.map(\.description).sorted().joined(separator: ", ")
        case let .wifiNetwork(value), let .ciscoAnyConnectVPN(value),
             let .volume(identifier: value), let .bluetoothDevice(identifier: value),
             let .usbDevice(identifier: value):
            identifierText = value
        case let .ipAddress(value):
            switch value {
            case let .exact(address):
                ipStartText = address.description
            case let .range(start, end):
                ipRangeMode = true
                ipStartText = start.description
                ipEndText = end.description
            }
        case let .application(value):
            identifierText = value.identifier
            requiresFrontmost = value.requiresFrontmost
        case let .displays(value):
            ignoresBuiltInDisplay = value.ignoresBuiltInDisplay
            switch value.requirement {
            case .mainDisplayMirrored:
                displayMirrored = true
            case let .count(comparison, value):
                displayComparison = comparison
                displayCountText = String(value)
            }
        case let .audioOutput(value):
            switch value {
            case let .device(identifier):
                audioKind = .device
                identifierText = identifier
            case .builtInOutput:
                audioKind = .builtInOutput
            case .builtInSpeakers:
                audioKind = .builtInSpeakers
            case .wiredHeadphones:
                audioKind = .wiredHeadphones
            }
        case let .batteryAndPowerAdapter(value):
            if let minimum = value.minimumBatteryPercentage {
                batteryMinimumEnabled = true
                batteryMinimumText = String(minimum)
            }
            if let adapter = value.powerAdapter {
                adapterRequirementEnabled = true
                adapterRequirement = adapter
            }
            batteryCombination = value.combination
        }
    }

    func makeCriterion() throws -> TriggerCriterion {
        switch kind {
        case .schedule:
            return .schedule(ScheduleCriterion(
                weekdays: weekdays,
                startMinute: startMinute,
                endMinute: endMinute
            ))
        case .systemIdleTime:
            return .systemIdleTime(try threshold())
        case .dnsServer:
            let values = try parseAddresses(addressesText)
            return .dnsServer(values)
        case .wifiNetwork:
            return .wifiNetwork(identifierText)
        case .ipAddress:
            guard let start = IPAddress(ipStartText) else { throw IPDraftError.invalid }
            if ipRangeMode {
                guard let end = IPAddress(ipEndText) else { throw IPDraftError.invalid }
                return .ipAddress(.range(start: start, end: end))
            }
            return .ipAddress(.exact(start))
        case .ciscoAnyConnectVPN:
            return .ciscoAnyConnectVPN(identifierText)
        case .volume:
            return .volume(identifier: identifierText)
        case .application:
            return .application(ApplicationCriterion(
                identifier: identifierText,
                requiresFrontmost: requiresFrontmost
            ))
        case .cpuUtilization:
            return .cpuUtilization(try threshold())
        case .displays:
            let requirement: DisplayRequirement
            if displayMirrored {
                requirement = .mainDisplayMirrored
            } else if let count = Int(displayCountText.trimmingCharacters(in: .whitespacesAndNewlines)) {
                requirement = .count(comparison: displayComparison, value: count)
            } else {
                throw IPDraftError.invalid
            }
            return .displays(DisplayCriterion(
                requirement: requirement,
                ignoresBuiltInDisplay: ignoresBuiltInDisplay
            ))
        case .bluetoothDevice:
            return .bluetoothDevice(identifier: identifierText)
        case .audioOutput:
            switch audioKind {
            case .device:
                return .audioOutput(.device(identifier: identifierText))
            case .builtInOutput:
                return .audioOutput(.builtInOutput)
            case .builtInSpeakers:
                return .audioOutput(.builtInSpeakers)
            case .wiredHeadphones:
                return .audioOutput(.wiredHeadphones)
            }
        case .usbDevice:
            return .usbDevice(identifier: identifierText)
        case .batteryAndPowerAdapter:
            let minimum: Double?
            if batteryMinimumEnabled {
                guard let value = Double(batteryMinimumText), value.isFinite else {
                    throw IPDraftError.invalid
                }
                minimum = value
            } else {
                minimum = nil
            }
            return .batteryAndPowerAdapter(BatteryPowerCriterion(
                minimumBatteryPercentage: minimum,
                powerAdapter: adapterRequirementEnabled ? adapterRequirement : nil,
                combination: batteryCombination
            ))
        }
    }

    private func threshold() throws -> ThresholdCriterion {
        guard let value = Double(thresholdValueText), value.isFinite else {
            throw IPDraftError.invalid
        }
        return ThresholdCriterion(comparison: thresholdComparison, value: value)
    }

    private func parseAddresses(_ text: String) throws -> Set<IPAddress> {
        let tokens = text.split(separator: ",", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        guard !tokens.isEmpty, !tokens.contains(where: { $0.isEmpty }) else {
            throw IPDraftError.invalid
        }
        var values = Set<IPAddress>()
        for token in tokens {
            guard let ipAddress = IPAddress(token) else { throw IPDraftError.invalid }
            values.insert(ipAddress)
        }
        guard !values.isEmpty else { throw IPDraftError.invalid }
        return values
    }
}

private struct TriggerDraft {
    var name: String
    var isEnabled: Bool
    var criteria: [CriterionDraft]
    var allowsDisplaySleep: Bool
    var allowsClosedDisplaySleep: Bool
    var screenSaverMode: ScreenSaverDraftMode = .prevent
    var screenSaverDelayText = "15"
    var screenSaverExceptionsText = ""

    init(trigger: AwakeTrigger) {
        name = trigger.name
        isEnabled = trigger.isEnabled
        criteria = trigger.criteria.map(CriterionDraft.init(criterion:))
        allowsDisplaySleep = trigger.sessionOptions.allowsDisplaySleep
        allowsClosedDisplaySleep = trigger.sessionOptions.allowsClosedDisplaySleep
        screenSaverExceptionsText = trigger.sessionOptions.screenSaverExceptionIdentifiers
            .sorted()
            .joined(separator: ", ")
        switch trigger.sessionOptions.screenSaverPolicy {
        case .prevent:
            screenSaverMode = .prevent
        case let .allow(after):
            screenSaverMode = .allowAfter
            screenSaverDelayText = String(max(0, after / 60))
        }
    }

    func makeTrigger(id: UUID) throws -> AwakeTrigger {
        let delay: TimeInterval
        if screenSaverMode == .allowAfter {
            guard let minutes = Double(screenSaverDelayText), minutes.isFinite, minutes >= 0 else {
                throw IPDraftError.invalid
            }
            delay = minutes * 60
        } else {
            delay = 0
        }
        let options = AwakeSessionOptions(
            allowsDisplaySleep: allowsDisplaySleep,
            screenSaverPolicy: screenSaverMode == .prevent
                ? .prevent
                : .allow(after: delay),
            screenSaverExceptionIdentifiers: Set(
                screenSaverExceptionsText
                    .split(separator: ",", omittingEmptySubsequences: true)
                    .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            ),
            allowsClosedDisplaySleep: allowsClosedDisplaySleep
        )
        let trigger = AwakeTrigger(
            id: id,
            name: name,
            isEnabled: isEnabled,
            criteria: try criteria.map { try $0.makeCriterion() },
            sessionOptions: options
        )
        return try trigger.validated()
    }
}

private extension TriggerCriterion.Kind {
    var displayName: String {
        switch self {
        case .schedule: L("Trigger Schedule")
        case .systemIdleTime: L("Trigger System Idle")
        case .dnsServer: L("Trigger DNS Server")
        case .wifiNetwork: L("Trigger Wi-Fi Network")
        case .ipAddress: L("Trigger IP Address")
        case .ciscoAnyConnectVPN: L("Trigger Cisco VPN")
        case .volume: L("Trigger Volume")
        case .application: L("Trigger Application")
        case .cpuUtilization: L("Trigger CPU Utilization")
        case .displays: L("Trigger Displays")
        case .bluetoothDevice: L("Trigger Bluetooth Device")
        case .audioOutput: L("Trigger Audio Output")
        case .usbDevice: L("Trigger USB Device")
        case .batteryAndPowerAdapter: L("Trigger Battery and Power")
        }
    }

    var symbolName: String {
        switch self {
        case .schedule: "calendar"
        case .systemIdleTime: "hourglass"
        case .dnsServer, .wifiNetwork, .ipAddress, .ciscoAnyConnectVPN: "network"
        case .volume: "externaldrive"
        case .application: "app"
        case .cpuUtilization: "gauge.with.dots.needle.67percent"
        case .displays: "rectangle.on.rectangle"
        case .bluetoothDevice: "dot.radiowaves.left.and.right"
        case .audioOutput: "speaker.wave.2"
        case .usbDevice: "cable.connector"
        case .batteryAndPowerAdapter: "battery.100.bolt"
        }
    }
}

private extension TriggerWeekday {
    var shortDisplayName: String {
        switch self {
        case .sunday: L("Sun")
        case .monday: L("Mon")
        case .tuesday: L("Tue")
        case .wednesday: L("Wed")
        case .thursday: L("Thu")
        case .friday: L("Fri")
        case .saturday: L("Sat")
        }
    }
}
