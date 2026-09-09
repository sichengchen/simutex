// Link-time fake inventory: production never accepts a fixture environment variable.
#include "cli_bridge.h"
#include "core_simulator_bridge.h"
#include <stdlib.h>
#include <string.h>
SimutexCoreSimulatorConnection *simutex_core_simulator_connection_create(char **e) { (void)e; return (void *)1; }
void simutex_core_simulator_connection_destroy(SimutexCoreSimulatorConnection *c) { (void)c; }
int simutex_core_simulator_connection_event_fd(SimutexCoreSimulatorConnection *c) { (void)c; return -1; }
void simutex_core_simulator_connection_drain_events(SimutexCoreSimulatorConnection *c) { (void)c; }
void simutex_core_simulator_string_free(char *s) { free(s); }
char *simutex_core_simulator_connection_copy_inventory_json(SimutexCoreSimulatorConnection *c, char **e) {
    (void)c; (void)e;
    return strdup("{\"devices\":{\"com.apple.CoreSimulator.SimRuntime.iOS-27-0\":[{\"udid\":\"SIM-1\",\"name\":\"One\",\"state\":\"Booted\",\"isAvailable\":true},{\"udid\":\"SIM-2\",\"name\":\"Two\",\"state\":\"Shutdown\",\"isAvailable\":true}]}}");
}
int main(int argc, const char **argv) { return simutex_cli_run(argc-1, argv+1); }
