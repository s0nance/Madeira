#pragma once

#ifdef __cplusplus
extern "C" {
#endif

// Start Wine process initialization on a background thread.
// Must be called AFTER wineserver is running.
// prefix_path: path to the Wine prefix directory
// Returns 0 on success, -1 on error.
int wine_process_start(const char *prefix_path);

// Check if Wine process is running
int wine_process_is_running(void);

// Steam S0 net-test VPN gate: write C:\madeira-continue.flag into the
// prefix's drive_c so the paused winhttp-test.exe resumes to the Steam
// stage. Called by the "Continue Net Test" UI button after the user has
// detached the JIT debugger and switched VPNs. Returns 0 on success.
int madeira_write_continue_flag(void);

#ifdef __cplusplus
}
#endif

/* ml771: count the task's VM map entries in [4GB,6GB) and attribute them.
 * Callable at any point so the pool's page-per-entry split can be dated:
 * present at allocation, or accumulated during the session. */
void madeira_low_va_census(const char *when, void *rx, void *rw, size_t size);

/* ml793: ask the running session to close itself. See the implementation for
 * what the return value does and does not promise. */
int wine_process_request_stop(void);
