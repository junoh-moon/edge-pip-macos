#include <sys/socket.h>
#include <sys/un.h>
#include <sys/proc_info.h>
#include <libproc.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>

static int write_all(int fd, const void *data, size_t len) {
    const char *p=data;
    while(len) {
        ssize_t n=write(fd,p,len);
        if(n<0 && errno==EINTR) continue;
        if(n<=0) return 0;
        p+=n; len-=(size_t)n;
    }
    return 1;
}
int main(int argc, char **argv) {
    if(argc<2 || strcmp(argv[1], "chrome-extension://icmpiipbipgffidajlhnhpcacphagnko/")) return 1;
    signal(SIGPIPE,SIG_IGN);
    char path[1024]; if(!confstr(_CS_DARWIN_USER_TEMP_DIR,path,sizeof(path))) return 2;
    struct sockaddr_un addr={.sun_family=AF_UNIX};
    int n=snprintf(addr.sun_path,sizeof(addr.sun_path),"%sedgepip-control.sock",path);
    if(n<0 || (size_t)n>=sizeof(addr.sun_path)) return 2;
    int fd=socket(AF_UNIX,SOCK_STREAM,0);
    if(fd<0 || connect(fd,(struct sockaddr*)&addr,sizeof(addr))<0) return 3;
    // Report only the native host's browser ancestors, to distinguish running Edge profiles.
    char hello[512]; size_t used=(size_t)snprintf(hello,sizeof(hello),"{\"type\":\"browser\",\"pids\":[");
    pid_t pid=getppid();
    for(int i=0;i<8 && pid>1;i++) {
        used+=(size_t)snprintf(hello+used,sizeof(hello)-used,"%s%d",i?",":"",pid);
        struct proc_bsdinfo b; if(proc_pidinfo(pid,PROC_PIDTBSDINFO,0,&b,sizeof(b))!=sizeof(b)) break;
        pid=b.pbi_ppid;
    }
    used+=(size_t)snprintf(hello+used,sizeof(hello)-used,"]}");
    uint32_t bytes=(uint32_t)used;
    if(!write_all(fd,&bytes,sizeof(bytes)) || !write_all(fd,hello,used)) return 4;
    struct pollfd ends[2]={{STDIN_FILENO,POLLIN,0},{fd,POLLIN,0}};
    char buf[8192];
    for(;;) {
        if(poll(ends,2,-1)<0) {if(errno==EINTR) continue;break;}
        for(int i=0;i<2;i++) if(ends[i].revents) {
            ssize_t count=read(ends[i].fd,buf,sizeof(buf));
            if(count<=0 || !write_all(i?STDOUT_FILENO:fd,buf,(size_t)count)) return 0;
        }
    }
    return 0;
}
