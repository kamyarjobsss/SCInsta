#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

#include "../src/Launch/IXSessionPersist.h"

#ifdef __APPLE__
#include <mach-o/dyld.h>
#endif

static int read_suite(const char *docs, const char *suite) {
    char path[1024];
    char buf[64];
    FILE *file;
    size_t n;
    if (!IXSessionSuitePlist(docs, suite, path, sizeof path)) return 0;
    file = fopen(path, "r");
    if (!file) return 0;
    n = fread(buf, 1, sizeof buf - 1, file);
    fclose(file);
    buf[n] = 0;
    return strcmp(buf, "account=kept\n") == 0;
}

static int relaunch_ok(const char *docs) {
    return read_suite(docs, "group.com.burbn.instagram") &&
           read_suite(docs, "group.com.facebook.family");
}

static int exec_self(void) {
#ifdef __APPLE__
    char exe[4096];
    uint32_t size = sizeof exe;
    if (_NSGetExecutablePath(exe, &size) != 0) return 1;
    execl(exe, exe, "relaunch", (char *)NULL);
#else
    execl("/proc/self/exe", "ix-launch-smoke", "relaunch", (char *)NULL);
#endif
    return 1;
}

int main(int argc, char **argv) {
    const char *inject;
    char tmpl[] = "/tmp/ix-smoke-XXXXXX";
    char *docs;
    void *handle;
    pid_t pid;
    int status = 1;
    if (argc > 1 && strcmp(argv[1], "relaunch") == 0) {
        docs = getenv("IX_DOCS");
        return docs && relaunch_ok(docs) ? 0 : 1;
    }
    inject = getenv("IX_INJECT");
    if (!inject) {
        fprintf(stderr, "IX_INJECT is unset\n");
        return 1;
    }
    docs = mkdtemp(tmpl);
    if (!docs) return 1;
    if (setenv("IX_DOCS", docs, 1) != 0) return 1;
    handle = dlopen(inject, RTLD_NOW);
    if (!handle) {
        fprintf(stderr, "dlopen: %s\n", dlerror());
        return 1;
    }
    if (!relaunch_ok(docs)) {
        fprintf(stderr, "suite missing after inject\n");
        return 1;
    }
    pid = fork();
    if (pid < 0) return 1;
    if (pid == 0) return exec_self();
    if (waitpid(pid, &status, 0) < 0) return 1;
    if (!WIFEXITED(status) || WEXITSTATUS(status) != 0) {
        fprintf(stderr, "relaunch status %d\n", status);
        return 1;
    }
    printf("ok launch smoke\n");
    return 0;
}
