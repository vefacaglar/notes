import AppKit
import NotesCore

/// Creating, encrypting and decrypting notes (docs/format.md, "Encrypted notes"). Every step that touches files is
/// synchronous on the main actor, so no edit can slip in between writing, checking and removing; only the key
/// derivation (slow on purpose) runs elsewhere.
extension Workspace {
    static var lockedMeanwhile: String { L("The notes were locked meanwhile, so nothing was changed.") }

    /// Why `url` can't be encrypted: deleting a link or a file with several hard links would leave the plain text behind.
    private static func encryptionBlocker(_ url: URL) -> String? {
        let isLink = (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true
        let links = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.referenceCount] as? Int ?? 1
        guard isLink || links > 1 else { return nil }
        return L("This note is a link or has several hard links, so deleting the original would leave its text behind. It can't be encrypted.")
    }

    private struct EncryptionFailure: LocalizedError {
        let errorDescription: String?
    }

    // MARK: New encrypted note

    /// File > New Encrypted Note…, folder menus.
    func newEncryptedNote() {
        guard let folder = targetFolder else {
            errorMessage = L("There is no folder to save the note in. Add a folder to the workspace first.")
            return
        }
        ask(.newEncrypted(in: folder), name: NoteStore.untitledName)
    }

    func createEncryptedNote(named name: String, in parent: ItemID) {
        guard let root = root(parent.root) else { return }
        let folder = parent.isRoot ? nil : parent.path
        do {
            _ = try root.store.uniqueEncryptedURL(named: name, in: folder)
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        let keyring = Keyring.shared
        guard let password = keyring.newestPassword
            ?? PasswordPrompt.askNew(title: L("Create Encrypted Note"), message: L("Choose a password for “\(name)”. There is no way to recover a forgotten password."),
                                     button: L("Create"))
        else { return }
        let generation = keyring.generation
        Task {
            let key = await Task.detached(priority: .userInitiated) { NoteCrypto.newKey(password: password) }.value
            // Locked meanwhile: nothing was touched, and the key is not remembered.
            guard generation == keyring.generation else {
                errorMessage = Self.lockedMeanwhile
                return
            }
            finishCreatingEncryptedNote(named: name, in: root, folder: folder, key: key, password: password)
        }
    }

    @discardableResult
    func finishCreatingEncryptedNote(named name: String, in root: RootFolder, folder: String?, key: NoteCrypto.Key,
                                     password: String) -> URL? {
        do {
            let target = try root.store.uniqueEncryptedURL(named: name, in: folder)
            try NoteFile.write(try NoteCrypto.encrypt("", with: key), to: target.url)
            Keyring.shared.remember(password: password, key: key)
            query = ""
            refresh()
            open(target.url, newTab: true, focus: true)
            model?.itemsChanged(by: self)
            return target.url
        } catch {
            errorMessage = L("“\(name)” couldn't be created: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: Encrypt

    /// Whether the active document is a saved `.md` note that can be encrypted.
    var canEncryptActive: Bool {
        guard let document = activeDocument else { return false }
        return !document.isDraft && document.isNote && locate(document.url) != nil
    }

    func encryptActive() {
        guard let document = activeDocument, !document.isDraft, document.isNote, let item = locate(document.url) else { return }
        encrypt(item)
    }

    /// File > Encrypt…, sidebar menu: asks for the name first.
    func encrypt(_ item: ItemID) {
        guard !item.isRoot, NoteStore.isNote(item.path), let url = url(for: item), !FilePaths.isFolder(url) else { return }
        if let problem = Self.encryptionBlocker(url) {
            errorMessage = problem
            return
        }
        ask(.encrypt(item), name: NoteStore.displayName(item.path))
    }

    func startEncrypting(_ item: ItemID, named name: String) {
        guard let root = root(item.root),
              let path = saveDocuments(in: root, inside: item.path, cancelled: L("Encrypting was cancelled."))
        else { return }
        let parent = NoteStore.parent(path)
        do {
            _ = try root.store.uniqueEncryptedURL(named: name, in: parent.isEmpty ? nil : parent)
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        guard let password = askEncryptionPassword(for: NoteStore.displayName(path)) else { return }
        let generation = Keyring.shared.generation
        Task {
            let key = await Task.detached(priority: .userInitiated) { NoteCrypto.newKey(password: password) }.value
            // Locked meanwhile: the note is left untouched.
            guard generation == Keyring.shared.generation else {
                errorMessage = Self.lockedMeanwhile
                return
            }
            encrypt(path, in: root, named: name, key: key, password: password)
        }
    }

    /// The password for an encryption: the newest one entered (after a question) or a new one typed twice. Also
    /// says, before the first encryption of a run, that the original is deleted for good and copies elsewhere stay.
    private func askEncryptionPassword(for name: String) -> String? {
        let keyring = Keyring.shared
        var notice = L("The original note is deleted permanently, not moved to the Trash.")
        if !keyring.hasShownEncryptionNotice {
            notice += " " + L("Copies kept elsewhere (Time Machine, sync history, git) are not removed.")
        }
        let title = L("Encrypt “\(name)”?")
        if let existing = keyring.newestPassword {
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = notice + "\n" + L("It uses the password you entered earlier.")
            alert.addButton(withTitle: L("Encrypt Note"))
            alert.addButton(withTitle: L("Use Another Password"))
            alert.addButton(withTitle: L("Cancel"))
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                keyring.hasShownEncryptionNotice = true
                return existing
            case .alertSecondButtonReturn: break
            default: return nil
            }
        }
        let password = PasswordPrompt.askNew(title: title, message: notice + "\n" + L("There is no way to recover a forgotten password."),
                                             button: L("Encrypt Note"))
        if password != nil { keyring.hasShownEncryptionNotice = true }
        return password
    }

    /// Writes `<name>.mdenc`, reads it back and decrypts it to compare with the note, and only then deletes the `.md`
    /// (permanently: the Trash would keep the plain text). Any failure before that deletes the new file again and
    /// leaves the note as it was. The open document turns into the encrypted one in place.
    @discardableResult
    func encrypt(_ path: String, in root: RootFolder, named name: String, key: NoteCrypto.Key, password: String?) -> Bool {
        // Typing may have gone on while the key was derived.
        guard let path = saveDocuments(in: root, inside: path, cancelled: L("Encrypting was cancelled.")) else { return false }
        var created: URL?
        do {
            let oldURL = try root.store.url(for: path)
            if let problem = Self.encryptionBlocker(oldURL) { throw EncryptionFailure(errorDescription: problem) }
            let text = try NoteFile.read(oldURL)
            let parent = NoteStore.parent(path)
            let target = try root.store.uniqueEncryptedURL(named: name, in: parent.isEmpty ? nil : parent)
            let data = try NoteCrypto.encrypt(text, with: key)
            try NoteFile.write(data, to: target.url)
            created = target.url
            let back = try NoteFile.readData(target.url)
            guard back == data, try NoteCrypto.decrypt(back, with: key) == text else {
                throw EncryptionFailure(errorDescription: L("The encrypted file didn't match the note."))
            }
            let documents = NoteDocument.all.filter { !$0.isDraft && NoteDocument.canonical($0.url) == NoteDocument.canonical(oldURL) }
            guard try NoteFile.read(oldURL) == text,
                  documents.allSatisfy({ !$0.hasUnsavedChanges && NoteFile.normalized($0.text) == text })
            else { throw EncryptionFailure(errorDescription: L("The note changed meanwhile.")) }
            try FileManager.default.removeItem(at: oldURL)
            created = nil
            documents.forEach { $0.becomeEncrypted(target.url, key: key, data: data) }
            Keyring.shared.remember(password: password, key: key)
            model?.itemMoved(from: oldURL, to: target.url)
            itemMoved(in: root, from: path, to: target.path)
            model?.itemsChanged(by: self)
            return true
        } catch {
            if let created { try? FileManager.default.removeItem(at: created) }
            errorMessage = L("“\(name)” couldn't be encrypted, so the note was left as it was: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: Remove encryption

    /// Whether the active document is an unlocked encrypted note.
    var canRemoveEncryptionActive: Bool {
        guard let document = activeDocument else { return false }
        return document.isEncrypted && !document.isLocked && locate(document.url) != nil
    }

    /// The open, unlocked encrypted note for the file at `url`, if any.
    func unlockedDocument(at url: URL) -> NoteDocument? {
        let key = NoteDocument.canonical(url)
        return NoteDocument.all.first { $0.isEncrypted && !$0.isLocked && NoteDocument.canonical($0.url) == key }
    }

    func removeEncryptionActive() {
        if let document = activeDocument { removeEncryption(of: document) }
    }

    func removeEncryption(of document: NoteDocument) {
        guard document.isEncrypted, !document.isLocked else { return }
        let alert = NSAlert()
        alert.messageText = L("Remove encryption from “\(document.name)”?")
        alert.informativeText = L("A plain copy is written next to it and the encrypted file is moved to the Trash.")
        alert.addButton(withTitle: L("Remove"))
        alert.addButton(withTitle: L("Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard !document.isLocked else {
            errorMessage = Self.lockedMeanwhile
            return
        }
        performRemoveEncryption(of: document)
    }

    /// Writes `<name>.md`, reads it back to check it, then moves the `.mdenc` to the Trash. The document goes on in
    /// place as a hand-named plain note. A failure deletes the new `.md` again and leaves the note encrypted.
    @discardableResult
    func performRemoveEncryption(of document: NoteDocument) -> Bool {
        guard document.isEncrypted, !document.isLocked, let item = locate(document.url), let root = root(item.root) else { return false }
        guard document.flush() else { return false }
        // The file must still be what this note read or wrote; otherwise another app changed it and the reload decides.
        guard document.diskMatchesSavedBytes else {
            document.reloadIfChanged()
            errorMessage = L("“\(document.name)” was changed in another app, so its encryption wasn't removed. Try again.")
            return false
        }
        let text = NoteFile.normalized(document.text)
        let oldURL = document.url
        let parent = NoteStore.parent(item.path)
        let folder = parent.isEmpty ? nil : parent
        var created: URL?
        do {
            let newPath = try root.store.createNote(named: root.store.uniqueNoteName(document.name, in: folder), in: folder)
            let newURL = try root.store.url(for: newPath)
            created = newURL
            try NoteFile.write(text, to: newURL)
            guard try NoteFile.read(newURL) == text else {
                throw EncryptionFailure(errorDescription: L("The new file didn't match the note."))
            }
            guard !document.hasUnsavedChanges, NoteFile.normalized(document.text) == text else {
                throw EncryptionFailure(errorDescription: L("The note changed meanwhile."))
            }
            try root.store.trash(item.path)
            created = nil
            document.becomePlain(newURL)
            model?.itemMoved(from: oldURL, to: newURL)
            itemMoved(in: root, from: item.path, to: newPath)
            model?.itemsChanged(by: self)
            return true
        } catch {
            if let created { try? FileManager.default.removeItem(at: created) }
            errorMessage = L("The encryption of “\(document.name)” couldn't be removed, so the note was left as it was: \(error.localizedDescription)")
            return false
        }
    }
}
