#ifndef SIMUTEX_CORE_SIMULATOR_BRIDGE_H
#define SIMUTEX_CORE_SIMULATOR_BRIDGE_H

#ifdef __cplusplus
extern "C" {
#endif

typedef struct SimutexCoreSimulatorConnection SimutexCoreSimulatorConnection;

SimutexCoreSimulatorConnection *simutex_core_simulator_connection_create(
    char **error_message
);
void simutex_core_simulator_connection_destroy(
    SimutexCoreSimulatorConnection *connection
);

int simutex_core_simulator_connection_event_fd(
    SimutexCoreSimulatorConnection *connection
);
void simutex_core_simulator_connection_drain_events(
    SimutexCoreSimulatorConnection *connection
);

char *simutex_core_simulator_connection_copy_inventory_json(
    SimutexCoreSimulatorConnection *connection,
    char **error_message
);
void simutex_core_simulator_string_free(char *string);

#ifdef __cplusplus
}
#endif

#endif
