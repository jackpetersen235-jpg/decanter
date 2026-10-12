// decanter-game-host — the executable of "Decanter Game.app", nested inside Decanter.app.
//
// WHY THIS EXISTS. macOS Game Mode only engages for a fullscreen, frontmost process that has a
// games-category app identity. A game started the normal way (`wine game.exe`, or Steam's
// `-applaunch`) is an anonymous process — RunningBoard labels it `anon<wine>` — and Game Mode
// never turns on for it, even in native fullscreen. Measured 2026-10-12; see GAMING-STACK.md §7b.
//
// HOW. Decanter opens this bundle through LaunchServices (NSWorkspace), which registers the new
// process as an app with this bundle's identity (LSApplicationCategoryType = games). This program
// then `exec`s the Wine loader in place: same PID, so the game inherits that registration. It is
// the same mechanism the hand-made ~/Applications/Sekiro.app uses, without a separate .app per
// game (GameAppBuilder.swift explains why that generator was removed).
//
// INPUT, all from the environment Decanter passes in NSWorkspace.OpenConfiguration:
//   DECANTER_HOST_EXEC          absolute path of the Wine loader to exec (required)
//   DECANTER_HOST_CWD           working directory for the game (optional; a game writes its
//                               config relative to it — see the direct-exe branch in AppModel)
//   DECANTER_HOST_DYLD_<NAME>   restored as DYLD_<NAME> just before exec
//   argv[1...]                  passed through to the loader (the game exe and its arguments)
//
// WHY DYLD_* ARRIVES RENAMED. dyld variables are fragile in transit: SIP strips them whenever an
// Apple system binary is exec'd on the way, and LaunchServices makes no promise to forward them.
// Renaming them for the trip and restoring them here — in a process that is not SIP-protected,
// immediately before exec'ing a loader that is not either — is the one hop guaranteed to keep them.
//
// Failures are reported through os_log (subsystem com.decanter.gamehost), since a LaunchServices-
// launched app has no terminal to print to.

#include <errno.h>
#include <os/log.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

extern char **environ;

static const char kDyldPrefix[] = "DECANTER_HOST_DYLD_";

enum { EXIT_USAGE = 64, EXIT_EXEC_FAILED = 70 };

// Collect first, mutate after: setenv/unsetenv may reallocate `environ` under the iterator.
static void restoreDyldVariables(os_log_t log) {
    size_t count = 0;
    for (char **e = environ; *e; e++) {
        if (strncmp(*e, kDyldPrefix, sizeof kDyldPrefix - 1) == 0) count++;
    }
    if (count == 0) return;

    char **entries = calloc(count, sizeof *entries);
    if (!entries) return;
    size_t n = 0;
    for (char **e = environ; *e && n < count; e++) {
        if (strncmp(*e, kDyldPrefix, sizeof kDyldPrefix - 1) == 0) entries[n++] = strdup(*e);
    }

    for (size_t i = 0; i < n; i++) {
        char *entry = entries[i];
        if (!entry) continue;
        char *eq = strchr(entry, '=');
        if (eq) {
            *eq = '\0';
            const char *suffix = entry + sizeof kDyldPrefix - 1;   // e.g. "INSERT_LIBRARIES"
            size_t nameLen = strlen("DYLD_") + strlen(suffix) + 1;
            char *name = malloc(nameLen);
            if (name) {
                snprintf(name, nameLen, "DYLD_%s", suffix);
                setenv(name, eq + 1, 1);
                os_log(log, "restored %{public}s", name);
                free(name);
            }
            unsetenv(entry);   // entry is now just the original name
        }
        free(entry);
    }
    free(entries);
}

int main(int argc, char **argv) {
    os_log_t log = os_log_create("com.decanter.gamehost", "launch");

    const char *loaderEnv = getenv("DECANTER_HOST_EXEC");
    if (!loaderEnv || !*loaderEnv) {
        os_log_error(log, "DECANTER_HOST_EXEC is not set — nothing to launch");
        return EXIT_USAGE;
    }
    char *loader = strdup(loaderEnv);

    const char *cwd = getenv("DECANTER_HOST_CWD");
    if (cwd && *cwd && chdir(cwd) != 0) {
        // Not fatal: the game still runs, it just resolves relative paths against "/".
        os_log_error(log, "chdir(%{public}s) failed: %{public}s", cwd, strerror(errno));
    }

    restoreDyldVariables(log);
    unsetenv("DECANTER_HOST_EXEC");
    unsetenv("DECANTER_HOST_CWD");

    // argv for the loader: the loader itself, then everything we were given. A stray
    // "-psn_…" process-serial-number argument (very old LaunchServices behaviour) is dropped.
    char **args = calloc((size_t)argc + 1, sizeof *args);
    if (!args) return EXIT_EXEC_FAILED;
    int k = 0;
    args[k++] = loader;
    for (int i = 1; i < argc; i++) {
        if (strncmp(argv[i], "-psn_", 5) == 0) continue;
        args[k++] = argv[i];
    }
    args[k] = NULL;

    os_log(log, "exec %{public}s (%d argument(s))", loader, k - 1);
    execv(loader, args);

    os_log_error(log, "exec %{public}s failed: %{public}s", loader, strerror(errno));
    return EXIT_EXEC_FAILED;
}
