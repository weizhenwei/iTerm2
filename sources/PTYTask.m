// Debug option
#define PtyTaskDebugLog(fmt, ...)
// Use this instead to debug this module:
// #define PtyTaskDebugLog NSLog

#define MAXRW 1024

#import "Coprocess.h"
#import "DebugLogging.h"
#import "PreferencePanel.h"
#import "ProcessCache.h"
#import "PTYTask.h"
#import "TaskNotifier.h"
#import "iTermAdvancedSettingsModel.h"
#include "iTermFileDescriptorClient.h"
#include "shell_launcher.h"
#include <dlfcn.h>
#include <libproc.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mount.h>
#include <sys/msg.h>
#include <sys/select.h>
#include <sys/time.h>
#include <sys/user.h>
#include <unistd.h>
#include <util.h>

#define CTRLKEY(c) ((c)-'A'+1)

NSString *kCoprocessStatusChangeNotification = @"kCoprocessStatusChangeNotification";

static void
setup_tty_param(struct termios* term,
                struct winsize* win,
                int width,
                int height,
                BOOL isUTF8)
{
    memset(term, 0, sizeof(struct termios));
    memset(win, 0, sizeof(struct winsize));

    // UTF-8 input will be added on demand.
    term->c_iflag = ICRNL | IXON | IXANY | IMAXBEL | BRKINT | (isUTF8 ? IUTF8 : 0);
    term->c_oflag = OPOST | ONLCR;
    term->c_cflag = CREAD | CS8 | HUPCL;
    term->c_lflag = ICANON | ISIG | IEXTEN | ECHO | ECHOE | ECHOK | ECHOKE | ECHOCTL;

    term->c_cc[VEOF] = CTRLKEY('D');
    term->c_cc[VEOL] = -1;
    term->c_cc[VEOL2] = -1;
    term->c_cc[VERASE] = 0x7f;           // DEL
    term->c_cc[VWERASE] = CTRLKEY('W');
    term->c_cc[VKILL] = CTRLKEY('U');
    term->c_cc[VREPRINT] = CTRLKEY('R');
    term->c_cc[VINTR] = CTRLKEY('C');
    term->c_cc[VQUIT] = 0x1c;           // Control+backslash
    term->c_cc[VSUSP] = CTRLKEY('Z');
    term->c_cc[VDSUSP] = CTRLKEY('Y');
    term->c_cc[VSTART] = CTRLKEY('Q');
    term->c_cc[VSTOP] = CTRLKEY('S');
    term->c_cc[VLNEXT] = CTRLKEY('V');
    term->c_cc[VDISCARD] = CTRLKEY('O');
    term->c_cc[VMIN] = 1;
    term->c_cc[VTIME] = 0;
    term->c_cc[VSTATUS] = CTRLKEY('T');

    term->c_ispeed = B38400;
    term->c_ospeed = B38400;

    win->ws_row = height;
    win->ws_col = width;
    win->ws_xpixel = 0;
    win->ws_ypixel = 0;
}

@interface PTYTask ()
@property(atomic, assign) BOOL hasMuteCoprocess;
@property(atomic, assign) BOOL coprocessOnlyTaskIsDead;
@end

@implementation PTYTask {
    pid_t _serverPid;  // -1 when servers are not in use.
    pid_t _serverChildPid;  // -1 when servers are not in use.
    pid_t _childPid;  // -1 when servers are in use; otherwise is pid of child.
    int fd;
    int status;
    NSString* tty;
    NSString* path;
    BOOL hasOutput;

    NSLock* writeLock;  // protects writeBuffer
    NSMutableData* writeBuffer;

    NSString* logPath;
    NSFileHandle* logHandle;

    Coprocess *coprocess_;  // synchronized (self)
    BOOL brokenPipe_;
    NSString *command_;  // Command that was run if launchWithPath:arguments:etc was called

    // Number of spins of the select loop left before we tell the delegate we were deregistered.
    int _spinsNeeded;
    BOOL _paused;
}

+ (NSString *)commandByPrefixingServerCommand:(NSString *)command {
    if ([iTermAdvancedSettingsModel runJobsInServers]) {
        NSString *iterm2Binary =
            [[[NSBundle mainBundle] executablePath] stringWithEscapedShellCharacters];
        return [NSString stringWithFormat:@"%@ --server %@", iterm2Binary, command];
    } else {
        return command;
    }
}

- (id)init {
    self = [super init];
    if (self) {
        _serverPid = (pid_t)-1;
        _childPid = (pid_t)-1;
        fd = -1;
        _serverChildPid = -1;
        writeBuffer = [[NSMutableData alloc] init];
        writeLock = [[NSLock alloc] init];
    }
    return self;
}

- (void)dealloc {
    [[TaskNotifier sharedInstance] deregisterTask:self];

    // TODO: The use of killpg seems pretty sketchy. It takes a pgid_t, not a
    // pid_t. Are they guaranteed to always be the same for process group
    // leaders?
    if (_childPid > 0) {
        // Terminate an owned child.
        killpg(_childPid, SIGHUP);
    } else if (_serverChildPid) {
        // Kill a server-owned child.
        // TODO: Don't want to do this when Sparkle is upgrading.
        killpg(_serverChildPid, SIGHUP);
    }

    [self closeFileDescriptor];
    [writeLock release];
    [writeBuffer release];
    [tty release];
    [path release];
        [command_ release];

    @synchronized (self) {
        [[self coprocess] mainProcessDidTerminate];
        [coprocess_ release];
    }

    [super dealloc];
}

- (BOOL)hasBrokenPipe
{
    return brokenPipe_;
}

- (BOOL)paused {
    @synchronized(self) {
        return _paused;
    }
}

- (void)setPaused:(BOOL)paused {
    @synchronized(self) {
        _paused = paused;
    }
    // Start/stop selecting on our FD
    [[TaskNotifier sharedInstance] unblock];
}

static void HandleSigChld(int n)
{
    // This is safe to do because write(2) is listed in the sigaction(2) man page
    // as allowed in a signal handler.
    [[TaskNotifier sharedInstance] unblock];
}

- (NSString *)command
{
    return command_;
}

// Returns a NSMutableDictionary containing the key-value pairs defined in the
// global "environ" variable.
- (NSMutableDictionary *)mutableEnvironmentDictionary {
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    extern char **environ;
    if (environ != NULL) {
        for (int i = 0; environ[i]; i++) {
            NSString *kvp = [NSString stringWithUTF8String:environ[i]];
            NSRange equalsRange = [kvp rangeOfString:@"="];
            if (equalsRange.location != NSNotFound) {
                NSString *key = [kvp substringToIndex:equalsRange.location];
                NSString *value = [kvp substringFromIndex:equalsRange.location + 1];
                result[key] = value;
            } else {
                result[kvp] = @"";
            }
        }
    }
    return result;
}

// Returns an array of C strings terminated with a null pointer of the form
// KEY=VALUE that is based on this process's "environ" variable. Values passed
// in "env" are added or override existing environment vars. Both the returned
// array and all string pointers within it are malloced and should be free()d
// by the caller.
- (char **)environWithOverrides:(NSDictionary *)env {
    NSMutableDictionary *environmentDict = [self mutableEnvironmentDictionary];
    for (NSString *k in env) {
        environmentDict[k] = env[k];
    }
    char **environment = malloc(sizeof(char*) * (environmentDict.count + 1));
    int i = 0;
    for (NSString *k in environmentDict) {
        NSString *temp = [NSString stringWithFormat:@"%@=%@", k, environmentDict[k]];
        environment[i++] = strdup([temp UTF8String]);
    }
    environment[i] = NULL;
    return environment;
}

- (BOOL)tryToAttachToServerWithProcessId:(pid_t)thePid
                                 timeout:(NSTimeInterval)timeout {
    if (![iTermAdvancedSettingsModel runJobsInServers]) {
        return NO;
    }
    if (_serverChildPid != -1) {
        return NO;
    }

    NSTimeInterval timeoutTime = [NSDate timeIntervalSinceReferenceDate] + timeout;
    // TODO: Create the unix domain socket in the parent prior to forking to avoid the timeout silliness.
    NSTimeInterval delay = 0.01;
    while (1) {
        // TODO: This server code is super scary so I'm NSLog'ing it to make it easier to recover
        // logs. These should eventually become DLog's and the log statements in the server should
        // become LOG_DEBUG level.
        NSLog(@"tryToAttachToServerWithProcessId: Attempt to connect to server for pid %d", (int)thePid);
        FileDescriptorClientResult result = FileDescriptorClientRun(thePid);
        if (!result.ok) {
            NSLog(@"Failed with error %s", result.error);
            if (result.error && !strcmp(result.error, kFileDescriptorClientErrorCouldNotConnect)) {
                // Waiting for child process to start.
                if ([NSDate timeIntervalSinceReferenceDate] > timeoutTime) {
                    return NO;
                } else {
                    // Did the job die?
                    int jobStatus;
                    int rc = waitpid(thePid, &jobStatus, WNOHANG);
                    if (rc == thePid) {
                        // NOTE: jobStatus has various interesting tidbits in the low 8 bits and the
                        // return code in the high 8 bits. See the man page for wait(2) for details.
                        NSLog(@"Server died immediately with status %d", jobStatus);
                        return NO;
                    } else if (rc == -1) {
                        NSLog(@"Waitpid failed for pid %d with error %s", (int)thePid, strerror(errno));
                    }

                    // Back off and retry. We just started the server so it'll need a sec to begin
                    // listening.
                    NSLog(@"Failed to connect. Try again in %0.2f seconds", delay);
                    usleep(delay * 1000000);
                    delay = MIN(0.1, delay * 2);
                    continue;
                }
            } else {
                return NO;
            }
        }
        NSLog(@"Succeeded.");
        [self attachToServerWithFileDescriptor:result.ptyMasterFd
                               serverProcessId:thePid
                                childProcessId:result.childPid];
        return YES;
    }
}

- (void)attachToServerWithFileDescriptor:(int)ptyMasterFd
                         serverProcessId:(pid_t)serverPid
                          childProcessId:(pid_t)childPid {
    assert([iTermAdvancedSettingsModel runJobsInServers]);
    fd = ptyMasterFd;
    _serverPid = serverPid;
    _serverChildPid = childPid;
    [[TaskNotifier sharedInstance] registerTask:self];
}

// Like login_tty but makes fd 0 the master and fd 1 the slave.
static void MyLoginTTY(int master, int slave) {
    setsid();
    ioctl(slave, TIOCSCTTY, NULL);
    if (slave == 0) {
        dup2(slave, 2);
        slave = 2;
    }
    dup2(master, 0);
    dup2(slave, 1);
    if (master > 1) {
        close(master);
    }
    if (slave > 1) {
        close(slave);
    }
}

// Just like forkpty but fd 0 the master and fd 1 the slave.
static int MyForkPty(int *amaster,
                     char *name,
                     struct termios *termp,
                     struct winsize *winp) {
    assert([iTermAdvancedSettingsModel runJobsInServers]);
    int master;
    int slave;

    if (openpty(&master, &slave, name, termp, winp) == -1) {
        NSLog(@"openpty failed: %s", strerror(errno));
        return -1;
    }

    pid_t pid = fork();
    switch (pid) {
        case -1:
            // error
            NSLog(@"Fork failed: %s", strerror(errno));
            return -1;

        case 0:
            // child
            MyLoginTTY(master, slave);
            return 0;

        default:
            // parent
            *amaster = master;
            close(slave);
            return pid;
    }
}

- (void)launchWithPath:(NSString *)progpath
             arguments:(NSArray *)args
           environment:(NSDictionary *)env
                 width:(int)width
                height:(int)height
                isUTF8:(BOOL)isUTF8 {
    struct termios term;
    struct winsize win;
    char theTtyname[PATH_MAX];

    if ([iTermAdvancedSettingsModel runJobsInServers]) {
        // We want to run
        //   iTerm2 --server progpath args
        //  So create a new args array with [ --server, progpath, *args ]
        NSMutableArray *temp = [NSMutableArray array];
        [temp addObject:@"--server"];
        [temp addObject:progpath];
        [temp addObjectsFromArray:args];
        args = temp;

        // Now change progpath to run iTerm2.
        NSString *iterm2Binary =
            [[[NSBundle mainBundle] executablePath] stringWithEscapedShellCharacters];
        progpath = iterm2Binary;
    }

    [command_ autorelease];
    command_ = [progpath copy];
    path = [progpath copy];

    setup_tty_param(&term, &win, width, height, isUTF8);

    // Register a handler for the child death signal. There is some history here.
    // Originally, a do-nothing handler was registered with the following comment:
    //   We cannot ignore SIGCHLD because Sparkle (the software updater) opens a
    //   Safari control which uses some buggy Netscape code that calls wait()
    //   until it succeeds. If we wait() on its pid, that process locks because
    //   it doesn't check if wait()'s failure is ECHLD. Instead of wait()ing here,
    //   we reap our children when our select() loop sees that a pipes is broken.
    // In response to bug 2903, wherein select() fails to return despite the file
    // descriptor having EOF status, I changed the handler to unblock the task
    // notifier.
    signal(SIGCHLD, HandleSigChld);
    const char* argpath;
    argpath = [[progpath stringByStandardizingPath] UTF8String];

    int max = (args == nil) ? 0 : [args count];
    const char* argv[max + 2];

    argv[0] = [[progpath stringByStandardizingPath] UTF8String];
    if (args != nil) {
        int i;
        for (i = 0; i < max; ++i) {
            argv[i + 1] = [[args objectAtIndex:i] cString];
        }
    }
    argv[max + 1] = NULL;
    char **newEnviron = [self environWithOverrides:env];

    // Note: stringByStandardizingPath will automatically call stringByExpandingTildeInPath.
    const char *initialPwd = [[[env objectForKey:@"PWD"] stringByStandardizingPath] UTF8String];
    pid_t pid;
    if ([iTermAdvancedSettingsModel runJobsInServers]) {
        pid = _serverPid = MyForkPty(&fd, theTtyname, &term, &win);
    } else {
        pid = _childPid = forkpty(&fd, theTtyname, &term, &win);
    }
    if (pid == (pid_t)0) {
        // Do not start the new process with a signal handler.
        signal(SIGCHLD, SIG_DFL);
        signal(SIGPIPE, SIG_DFL);
        sigset_t signals;
        sigemptyset(&signals);
        sigaddset(&signals, SIGPIPE);
        sigprocmask(SIG_UNBLOCK, &signals, NULL);

        // Apple opens files without the close-on-exec flag (e.g., Extras2.rsrc).
        // See issue 2662.
        for (int j = 3; j < getdtablesize(); j++) {
            close(j);
        }

        chdir(initialPwd);

        // Sub in our environ for the existing one. Since Mac OS doesn't have execvpe, this hack
        // does the job.
        extern char **environ;
        environ = newEnviron;
        execvp(argpath, (char* const*)argv);

        /* exec error */
        fprintf(stdout, "## exec failed ##\n");
        fprintf(stdout, "argpath=%s error=%s\n", argpath, strerror(errno));

        sleep(1);
        _exit(-1);
    } else if (pid < (pid_t)0) {
        PtyTaskDebugLog(@"%@ %s", progpath, strerror(errno));
        NSRunCriticalAlertPanel(@"Unable to Fork!",
                                @"iTerm cannot launch the program for this session.",
                                @"OK",
                                nil,
                                nil);
        for (int j = 0; newEnviron[j]; j++) {
            free(newEnviron[j]);
        }
        free(newEnviron);
        return;
    }
    for (int j = 0; newEnviron[j]; j++) {
        free(newEnviron[j]);
    }
    free(newEnviron);

    // Make sure the master side of the pty is closed on future exec() calls.
    fcntl(fd, F_SETFD, fcntl(fd, F_GETFD) | FD_CLOEXEC);

    if ([iTermAdvancedSettingsModel runJobsInServers]) {
        // Unfortunately, we have to attach to the newly created server in order to get the child's
        // process ID. Without it, we can't kill our children or get their working directories. It
        // takes some unkown amount of time for the server to be ready to accept connections.
        // I did try creating the connection before starting the server but it was way too complex
        // to create a socket and connect to it in a single process/thread, and I'm afraid of the
        // bugs I'd run into if I tried to do it with multiple threads.
        if ([self tryToAttachToServerWithProcessId:_serverPid timeout:10]) {
            tty = [[NSString stringWithUTF8String:theTtyname] retain];
            fcntl(fd, F_SETFL, O_NONBLOCK);
        } else {
            close(fd);
            NSLog(@"Server died immediately!");
            [_delegate brokenPipe];
        }
    } else {
        tty = [[NSString stringWithUTF8String:theTtyname] retain];
        fcntl(fd,F_SETFL,O_NONBLOCK);
        [[TaskNotifier sharedInstance] registerTask:self];
    }
}

- (void)registerAsCoprocessOnlyTask {
    self.isCoprocessOnly = YES;
    [[TaskNotifier sharedInstance] registerTask:self];
}

- (void)writeToCoprocessOnlyTask:(NSData *)data {
    if (self.coprocess) {
        TaskNotifier *taskNotifier = [TaskNotifier sharedInstance];
        [taskNotifier lock];
        @synchronized (self) {
            [self.coprocess.outputBuffer appendData:data];
        }
        [taskNotifier unlock];

        // Wake up the task notifier so the coprocess's output buffer will be sent to its file
        // descriptor.
        [taskNotifier unblock];
    }
}

- (BOOL)wantsRead {
    return !self.paused;
}

- (BOOL)wantsWrite
{
    if (self.paused) {
        return NO;
    }
    [writeLock lock];
    BOOL wantsWrite = [writeBuffer length] > 0;
    [writeLock unlock];
    return wantsWrite;
}

- (BOOL)writeBufferHasRoom
{
    const int kMaxWriteBufferSize = 1024 * 10;
    [writeLock lock];
    BOOL hasRoom = [writeBuffer length] < kMaxWriteBufferSize;
    [writeLock unlock];
    return hasRoom;
}

- (void)processRead
{
    int iterations = 4;
    int bytesRead = 0;

    char buffer[MAXRW * iterations];
    for (int i = 0; i < iterations; ++i) {
        // Only read up to MAXRW*iterations bytes, then release control
        ssize_t n = read(fd, buffer + bytesRead, MAXRW);
        if (n < 0) {
            // There was a read error.
            if (errno != EAGAIN && errno != EINTR) {
                // It was a serious error.
                [self brokenPipe];
                return;
            } else {
                // We could read again in the case of EINTR but it would
                // complicate the code with little advantage. Just bail out.
                n = 0;
            }
        }
        bytesRead += n;
        if (n < MAXRW) {
            // If we read fewer bytes than expected, return. For some apparently
            // undocumented reason, read() never returns more than 1024 bytes
            // (at least on OS 10.6), so that's what MAXRW is set to. If that
            // ever goes down this'll break.
            break;
        }
    }

    hasOutput = YES;

    // Send data to the terminal
    [self readTask:buffer length:bytesRead];
}

- (void)processWrite
{
    // Retain to prevent the object from being released during this method
    // Lock to protect the writeBuffer from the main thread
    [self retain];
    [writeLock lock];

    // Only write up to MAXRW bytes, then release control
    char* ptr = [writeBuffer mutableBytes];
    unsigned int length = [writeBuffer length];
    if (length > MAXRW) {
        length = MAXRW;
    }
    ssize_t written = write(fd, [writeBuffer mutableBytes], length);

    // No data?
    if ((written < 0) && (!(errno == EAGAIN || errno == EINTR))) {
        [self brokenPipe];
    } else if (written > 0) {
        // Shrink the writeBuffer
        length = [writeBuffer length] - written;
        memmove(ptr, ptr+written, length);
        [writeBuffer setLength:length];
    }

    // Clean up locks
    [writeLock unlock];
    [self autorelease];
}

- (BOOL)hasOutput
{
    return hasOutput;
}

- (void)logData:(const char *)buffer length:(int)length {
    @synchronized(logHandle) {
        if ([self logging]) {
            [logHandle writeData:[NSData dataWithBytes:buffer
                                                length:length]];
        }
    }
}

// The bytes in data were just read from the fd.
- (void)readTask:(char *)buffer length:(int)length
{
    [self logData:buffer length:length];

    // The delegate is responsible for parsing VT100 tokens here and sending them off to the
    // main thread for execution. If its queues get too large, it can block.
    [self.delegate threadedReadTask:buffer length:length];

    @synchronized (self) {
        if (coprocess_) {
            [coprocess_.outputBuffer appendData:[NSData dataWithBytes:buffer length:length]];
        }
    }
}

- (void)writeTask:(NSData*)data
{
    if (self.isCoprocessOnly) {
        // Send keypresses to tmux.
        [_delegate retain];
        NSData *copyOfData = [data copy];
        dispatch_async(dispatch_get_main_queue(), ^{
            [_delegate writeForCoprocessOnlyTask:copyOfData];
            [_delegate release];
            [copyOfData release];
        });
    } else {
        // Write as much as we can now through the non-blocking pipe
        // Lock to protect the writeBuffer from the IO thread
        [writeLock lock];
        [writeBuffer appendData:data];
        [[TaskNotifier sharedInstance] unblock];
        [writeLock unlock];
    }
}

- (void)brokenPipe {
    brokenPipe_ = YES;
    [[TaskNotifier sharedInstance] deregisterTask:self];
    [self.delegate threadedTaskBrokenPipe];
}

- (void)sendSignal:(int)signo {
    if (_serverChildPid != -1) {
        kill(_serverChildPid, signo);
     } else if (_childPid >= 0) {
         kill(_childPid, signo);
     }
}

// Sends a signal to the server. This breaks it out of accept()ing forever when iTerm2 quits.
- (void)killServerIfRunning {
    if (_serverPid >= 0) {
        kill(_serverPid, SIGUSR1);
        // It should die right away.
        int rc;
        int theError;
        do {
            DLog(@"waitpid on %d", _serverPid);
            rc = waitpid(_serverPid, &status, 0);
            theError = errno;
            DLog(@"waitpid returned %d error=%s", rc, strerror(theError));
        } while (rc == -1 && theError == EINTR);
        NSLog(@"Server is dead");
    }
}

- (void)setWidth:(int)width height:(int)height
{
    PtyTaskDebugLog(@"Set terminal size to %dx%d", width, height);
    struct winsize winsize;
    // TODO(georgen): Access to fd should be synchronized or else it should not be allowed to call this function from the main thread.
    if (fd == -1) {
        return;
    }

    ioctl(fd, TIOCGWINSZ, &winsize);
    if ((winsize.ws_col != width) || (winsize.ws_row != height)) {
        winsize.ws_col = width;
        winsize.ws_row = height;
        ioctl(fd, TIOCSWINSZ, &winsize);
    }
}

- (int)fd
{
    return fd;
}

- (BOOL)pidIsChild {
    return _serverChildPid == 1 && _childPid != -1;
}

- (pid_t)serverPid {
    return _serverPid;
}

- (pid_t)pid {
    if (_serverChildPid != -1) {
        return _serverChildPid;
    } else {
        return _childPid;
    }
}

- (void)closeFileDescriptor {
    if (fd != -1) {
        close(fd);
    }
}

- (void)stop
{
    self.paused = NO;
    [self loggingStop];
    [self sendSignal:SIGHUP];
    [self killServerIfRunning];

    if (fd >= 0) {
        [self closeFileDescriptor];
        [[TaskNotifier sharedInstance] deregisterTask:self];
        // Require that it spin twice so we can be completely sure that the task won't get called
        // again. If we add the observer just before select() was going to be called, it wouldn't
        // mean anything; but after the second call, we know we've been moved into the dead pool.
        @synchronized(self) {
            _spinsNeeded = 2;
        }
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(notifierDidSpin)
                                                     name:kTaskNotifierDidSpin
                                                   object:nil];
        // Force a spin
        [[TaskNotifier sharedInstance] unblock];

        // This isn't an atomic update, but select() should be resilient to
        // being passed a half-broken fd. We must change it because after this
        // function returns, a new task may be created with this fd and then
        // the select thread wouldn't know which task a fd belongs to.
        fd = -1;
    }
    if (self.isCoprocessOnly) {
        self.coprocessOnlyTaskIsDead = YES;
    }
}

// This runs in TaskNotifier's thread.
- (void)notifierDidSpin
{
    BOOL unblock = NO;
    @synchronized(self) {
        unblock = (--_spinsNeeded) > 0;
    }
    if (unblock) {
        // Force select() to return so we get another spin even if there is no
        // activity on the file descriptors.
        [[TaskNotifier sharedInstance] unblock];
    } else {
        [[NSNotificationCenter defaultCenter] removeObserver:self];
        [self.delegate taskWasDeregistered];
    }
}

- (int)status
{
    return status;
}

- (NSString*)tty
{
    return tty;
}

- (NSString*)path
{
    return path;
}

- (BOOL)loggingStartWithPath:(NSString*)aPath
{
    BOOL rc;
    @synchronized(logHandle) {
        [logPath autorelease];
        logPath = [[aPath stringByStandardizingPath] copy];

        [logHandle autorelease];
        logHandle = [NSFileHandle fileHandleForWritingAtPath:logPath];
        if (logHandle == nil) {
            NSFileManager* fm = [NSFileManager defaultManager];
            [fm createFileAtPath:logPath contents:nil attributes:nil];
            logHandle = [NSFileHandle fileHandleForWritingAtPath:logPath];
        }
        [logHandle retain];
        [logHandle truncateFileAtOffset:0];

        rc = (logHandle == nil ? NO : YES);
    }
    return rc;
}

- (void)loggingStop
{
    @synchronized(logHandle) {
        [logHandle closeFile];

        [logPath autorelease];
        [logHandle autorelease];
        logPath = nil;
        logHandle = nil;
    }
}

- (BOOL)logging
{
    BOOL rc;
    @synchronized(logHandle) {
        rc = (logHandle == nil ? NO : YES);
    }
    return rc;
}

- (NSString*)description {
    return [NSString stringWithFormat:@"PTYTask(child pid %d, server-child pid %d, fildes %d)",
              _serverChildPid, _serverPid, fd];
}

// This is a stunningly brittle hack. Find the child of parentPid with the
// oldest start time. This relies on undocumented APIs, but short of forking
// ps, I can't see another way to do it.

- (pid_t)getFirstChildOfPid:(pid_t)parentPid {
    int numBytes;
    numBytes = proc_listpids(PROC_ALL_PIDS, 0, NULL, 0);
    if (numBytes <= 0) {
        return -1;
    }

    int* pids = (int*) malloc(numBytes + sizeof(int));
    // Save a magic int at the end to be sure that the buffer isn't overrun.
    const int PID_MAGIC = 0xdeadbeef;
    int magicIndex = numBytes/sizeof(int);
    pids[magicIndex] = PID_MAGIC;
    numBytes = proc_listpids(PROC_ALL_PIDS, 0, pids, numBytes);
    assert(pids[magicIndex] == PID_MAGIC);
    if (numBytes <= 0) {
        free(pids);
        return -1;
    }

    int numPids = numBytes / sizeof(int);

    long long oldestTime = 0;
    pid_t oldestPid = -1;
    for (int i = 0; i < numPids; ++i) {
        struct proc_taskallinfo taskAllInfo;
        int rc = proc_pidinfo(pids[i],
                              PROC_PIDTASKALLINFO,
                              0,
                              &taskAllInfo,
                              sizeof(taskAllInfo));
        if (rc <= 0) {
            continue;
        }

        pid_t ppid = taskAllInfo.pbsd.pbi_ppid;
        if (ppid == parentPid) {
            long long birthday = taskAllInfo.pbsd.pbi_start_tvsec * 1000000 + taskAllInfo.pbsd.pbi_start_tvusec;
            if (birthday < oldestTime || oldestTime == 0) {
                oldestTime = birthday;
                oldestPid = pids[i];
            }
        }
    }

    assert(pids[magicIndex] == PID_MAGIC);
    free(pids);
    return oldestPid;
}

// Get the name of this task's current job. It is quite approximate! Any
// arbitrary tty-controller in the tty's pgid that has this task as an ancestor
// may be chosen. This function also implements a chache to avoid doing the
// potentially expensive system calls too often.
- (NSString*)currentJob:(BOOL)forceRefresh {
    return [[ProcessCache sharedInstance] jobNameWithPid:self.pid];
}

- (NSString*)getWorkingDirectory {
    struct proc_vnodepathinfo vpi;
    int ret;

    // This only works if the child process is owned by our uid
    // Notably it seems to work (at least on 10.10) even if the process ID is
    // not owned by us.
    ret = proc_pidinfo(self.pid, PROC_PIDVNODEPATHINFO, 0, &vpi, sizeof(vpi));
    if (ret <= 0) {
        // The child was probably owned by root (which is expected if it's
        // a login shell. Use the cwd of its oldest child instead.
        pid_t childPid = [self getFirstChildOfPid:self.pid];
        if (childPid > 0) {
            ret = proc_pidinfo(childPid, PROC_PIDVNODEPATHINFO, 0, &vpi, sizeof(vpi));
        }
    }
    if (ret <= 0) {
        // An error occured
        return nil;
    } else if (ret != sizeof(vpi)) {
        // Now this is very bad...
        return nil;
    } else {
        // All is good
        return [NSString stringWithUTF8String:vpi.pvi_cdir.vip_path];
    }
}

- (void)stopCoprocess {
    pid_t thePid = 0;
    @synchronized (self) {
        if (coprocess_.pid > 0) {
            thePid = coprocess_.pid;
        }
        [coprocess_ terminate];
        [coprocess_ release];
        coprocess_ = nil;
        self.hasMuteCoprocess = NO;
    }
    if (thePid) {
        [[TaskNotifier sharedInstance] waitForPid:thePid];
    }
    [[TaskNotifier sharedInstance] performSelectorOnMainThread:@selector(notifyCoprocessChange)
                                                    withObject:nil
                                                 waitUntilDone:NO];
}

- (void)setCoprocess:(Coprocess *)coprocess
{
    @synchronized (self) {
        [coprocess_ autorelease];
        coprocess_ = [coprocess retain];
        self.hasMuteCoprocess = coprocess_.mute;
    }
    [[TaskNotifier sharedInstance] unblock];
}

- (Coprocess *)coprocess
{
    @synchronized (self) {
        return coprocess_;
    }
    return nil;
}

- (BOOL)hasCoprocess
{
    @synchronized (self) {
        return coprocess_ != nil;
    }
    return NO;
}

@end

