/// Workspace snapshot status only; not a transaction result for shells, WebKit or other files.
public enum WorkspacePersistence: String, CaseIterable, Sendable {
    case saved, disabled, suspended, failed, notRequired
}
