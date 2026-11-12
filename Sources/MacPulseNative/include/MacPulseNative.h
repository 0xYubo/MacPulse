#ifndef MACPULSE_NATIVE_H
#define MACPULSE_NATIVE_H

#include <stdint.h>

typedef struct {
    uint64_t user;
    uint64_t system;
    uint64_t idle;
    uint64_t nice;
} MPCPUTicks;

typedef struct {
    uint64_t user_time_ns;
    uint64_t system_time_ns;
    uint64_t physical_footprint;
    uint64_t start_time;
} MPProcessMetrics;

int32_t mp_read_cpu_ticks(MPCPUTicks *result);
int32_t mp_read_process_metrics(int32_t pid, MPProcessMetrics *result);
int32_t mp_read_process_cwd(int32_t pid, char *buffer, uint32_t size);

#endif
