import Darwin
import notify
import Foundation

final class CaptureGuard {
    private let fd: Int32
    private var token: Int32 = 0
    private var observing = false

    init() {
        var temp = [CChar](repeating: 0, count: Int(PATH_MAX))
        let size = confstr(_CS_DARWIN_USER_TEMP_DIR, &temp, temp.count)
        guard size > 0 && size <= temp.count else { fd = -1; return }
        let path = String(cString: temp) + "edgepip-protected-playback.lock"
        fd = open(path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
    }

    var isBlockingCapture: Bool {
        guard fd >= 0 && flock(fd, LOCK_EX | LOCK_NB) == 0 else { return true }
        flock(fd, LOCK_UN)
        return false
    }

    func observe(_ changed: @escaping () -> Void) {
        observing = notify_register_dispatch("local.edgepip.companion.protection-changed", &token, .main) { _ in
            changed()
        } == NOTIFY_STATUS_OK
    }

    deinit {
        if observing { notify_cancel(token) }
        if fd >= 0 { close(fd) }
    }
}
