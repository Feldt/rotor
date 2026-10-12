import Foundation

/// The inline "+ Name" row before Return. Pure UI state: cancelling never quits Claude or writes.
public struct AddDraft: Sendable, Equatable {
    public private(set) var isOpen = false
    public var name = ""

    public init() {}

    public mutating func open() { isOpen = true }

    /// × or Escape: remove the row and forget the text.
    public mutating func cancel() {
        isOpen = false
        name = ""
    }

    /// Closing the panel drops an empty row; a typed name stays until submitted or cancelled.
    public mutating func panelClosed() {
        if name.trimmingCharacters(in: .whitespaces).isEmpty { cancel() }
    }

    /// Return: the label to start the add with (closing the row), or nil if it's blank.
    public mutating func submit() -> String? {
        let label = name.trimmingCharacters(in: .whitespaces)
        guard label.isEmpty == false else { return nil }
        cancel()
        return label
    }
}
