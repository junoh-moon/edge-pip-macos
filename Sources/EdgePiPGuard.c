// A native-messaging connection lives exactly as long as its protected frame.
// Shared locks let independent tabs pause capture without unlocking each other.
#include <sys/file.h>
#include <sys/stat.h>
#include <notify.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char **argv) {
    if (argc < 2 || strcmp(argv[1], "chrome-extension://icmpiipbipgffidajlhnhpcacphagnko/") != 0)
        return 1;
    char directory[PATH_MAX], path[PATH_MAX];
    size_t length = confstr(_CS_DARWIN_USER_TEMP_DIR, directory, sizeof(directory));
    if (length == 0 || length > sizeof(directory)) return 2;
    int written = snprintf(path, sizeof(path), "%sedgepip-protected-playback.lock", directory);
    if (written < 0 || written >= (int)sizeof(path)) return 2;
    int fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR);
    if (fd < 0 || flock(fd, LOCK_SH) != 0) return 3;
    const char *change = "local.edgepip.companion.protection-changed";
    notify_post(change);
    char ignored[256];
    ssize_t count;
    do { count = read(STDIN_FILENO, ignored, sizeof(ignored)); }
    while (count > 0 || (count < 0 && errno == EINTR));
    close(fd);
    notify_post(change);
    return 0;
}
