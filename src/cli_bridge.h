#ifndef SIMUTEX_CLI_BRIDGE_H
#define SIMUTEX_CLI_BRIDGE_H
int simutex_cli_run(int argc, const char * const *argv);
int simutex_guard_acquire(int directory_fd);
void simutex_guard_release(int fd);
char *simutex_copy_description(const char *udid);
#endif
