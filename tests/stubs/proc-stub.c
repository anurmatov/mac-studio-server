/*
 * proc-stub.c: a process that only waits, for the real-process Ollama worker
 * tests (#35 W15, W16, W16b). The test compiles it with cc and copies it to
 * <dir>/ollama, run as `<dir>/ollama serve`. With PROC_STUB_CHILD naming a
 * file of argv lines (the first is the program's path), it forks and execs
 * that child directly, as `ollama serve` execs its llama-server, and writes
 * the child's pid to PROC_STUB_PIDFILE when set. The child never sees
 * PROC_STUB_CHILD, so it does not spawn again. Both wait until killed; TERM
 * to the parent takes the child with it.
 */
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

static pid_t child = 0;

static void stop(int sig)
{
    (void)sig;
    if (child > 0)
        kill(child, SIGTERM);
    _exit(0);
}

int main(void)
{
    const char *spec = getenv("PROC_STUB_CHILD");
    const char *pidfile = getenv("PROC_STUB_PIDFILE");
    char *args[64];
    char line[8192];
    int n = 0;
    FILE *f;

    signal(SIGTERM, stop);
    if (spec != NULL && *spec != '\0') {
        f = fopen(spec, "r");
        if (f == NULL) {
            perror(spec);
            return 1;
        }
        while (n < 63 && fgets(line, sizeof line, f) != NULL) {
            line[strcspn(line, "\n")] = '\0';
            args[n++] = strdup(line);
        }
        fclose(f);
        args[n] = NULL;
        if (n == 0) {
            fprintf(stderr, "proc-stub: %s has no argv\n", spec);
            return 1;
        }
        unsetenv("PROC_STUB_CHILD");
        unsetenv("PROC_STUB_PIDFILE");
        child = fork();
        if (child < 0) {
            perror("fork");
            return 1;
        }
        if (child == 0) {
            signal(SIGTERM, SIG_DFL);
            execv(args[0], args);
            perror(args[0]);
            _exit(127);
        }
        if (pidfile != NULL && *pidfile != '\0') {
            f = fopen(pidfile, "w");
            if (f == NULL) {
                perror(pidfile);
                return 1;
            }
            fprintf(f, "%d\n", (int)child);
            fclose(f);
        }
    }
    for (;;)
        pause();
}
