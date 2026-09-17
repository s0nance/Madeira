/* Wrapper: include original main.c but add iOS logging around init */
#include <os/log.h>
#include "wine_log_ios.h"
#define main wineserver_main_original
#include "main.c"
#undef main

/* ml764: the server is initialised ONCE per process, and resumed after that.
 *
 * A second Wine session called wineserver_main again, which walked the whole
 * init sequence a second time and died:
 *
 *   [wineserver] init_registry...
 *   Assertion failed: (root_key), function init_registry, registry.c line 1913
 *
 * create_key_object returns NULL there because \REGISTRY already exists --
 * the first session created it OBJ_PERMANENT and nothing removed it. That is
 * not an obstacle to route around, it is the server stating a fact: its
 * object namespace, its registry, its directories and its threading are all
 * still valid, and re-initialising them is precisely the wrong move.
 *
 * main_loop() returns on our own stop flag (fd_ios.c) and leaves every bit of
 * that state untouched, so a resumed session simply re-enters the loop and
 * finds the server it left behind. This is also how upstream Wine already
 * works -- wineserver outlives the processes that talk to it. Here it is a
 * thread instead of a process, which changes where it lives, not whether it
 * persists.
 *
 * Set before main_loop, not after: main_loop is the part that runs for the
 * whole session, and a flag set on the far side of it would never be seen.
 */
static int ws_initialised = 0;

/* Our replacement that adds logging */
int wineserver_main(int argc, char *argv[])
{
    if (ws_initialised)
    {
        ws_log("[wineserver] ml764 already initialised -- re-entering main_loop only");
        main_loop();
        ws_log("[wineserver] main_loop returned (resumed session)");
        return 0;
    }

    ws_log("[wineserver] starting init...");
    setvbuf( stderr, NULL, _IOLBF, 0 );
    server_argv0 = argv[0];
    parse_options( argc, argv, "d::fhk::p::vw", long_options, option_callback );

    signal( SIGPIPE, SIG_IGN );
    /* iOS: Don't install sigterm_handler — it calls exit(1) which kills the whole app.
     * Signals are process-wide, so the Wine client thread could trigger them. */
    signal( SIGHUP, SIG_IGN );
    signal( SIGINT, SIG_IGN );
    signal( SIGQUIT, SIG_IGN );
    signal( SIGTERM, SIG_IGN );
    /* Don't ignore SIGABRT — it's useful for crash debugging */

    /* iOS: wineserver runs as a thread in the same process as the client.
     * Don't exit(0) when no clients connect within 3 seconds — the client
     * thread may take a while to start. Also, exit() would kill the whole app. */
    master_socket_timeout = TIMEOUT_INFINITE;
    ws_log("[wineserver] master_socket_timeout set to INFINITE (%lld)", (long long)master_socket_timeout);
    ws_log("[wineserver] init_limits...");
    init_limits();

    ws_log("[wineserver] sock_init...");
    sock_init();
    ws_log("[wineserver] open_master_socket...");
    open_master_socket();

    ws_log("[wineserver] init_signals...");
    set_current_time();
    init_signals();
    ws_log("[wineserver] init_memory...");
    init_memory();
    ws_log("[wineserver] load_intl_file + init_directories...");
    init_directories( load_intl_file() );
    ws_log("[wineserver] init_threading...");
    init_threading();
    ws_log("[wineserver] init_registry...");
    init_registry();
    ws_initialised = 1;
    ws_log("[wineserver] entering main_loop!");
    main_loop();
    ws_log("[wineserver] main_loop returned");
    return 0;
}
