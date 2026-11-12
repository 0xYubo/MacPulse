#include "MacPulseNative.h"

#include <dispatch/dispatch.h>
#include <libproc.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <string.h>
#include <sys/resource.h>

int32_t mp_read_cpu_ticks(MPCPUTicks *result) {
    if (result == NULL) {
        return -1;
    }

    host_cpu_load_info_data_t load = {0};
    mach_msg_type_number_t count = HOST_CPU_LOAD_INFO_COUNT;
    kern_return_t status = host_statistics(
        mach_host_self(), HOST_CPU_LOAD_INFO, (host_info_t)&load, &count
    );
    if (status != KERN_SUCCESS) {
        return status;
    }

    result->user = load.cpu_ticks[CPU_STATE_USER];
    result->system = load.cpu_ticks[CPU_STATE_SYSTEM];
    result->idle = load.cpu_ticks[CPU_STATE_IDLE];
    result->nice = load.cpu_ticks[CPU_STATE_NICE];
    return 0;
}

// rusage 的 ri_user_time / ri_system_time 以 mach absolute time 为单位：
// Intel 上恰好等于纳秒，Apple Silicon 上是 24MHz tick（numer/denom = 125/3），必须换算，否则 CPU% 会低估约 41.7 倍。
static uint64_t mp_mach_ticks_to_ns(uint64_t ticks) {
    static mach_timebase_info_data_t timebase = {0, 0};
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (mach_timebase_info(&timebase) != KERN_SUCCESS || timebase.denom == 0) {
            timebase.numer = 1;
            timebase.denom = 1;
        }
    });
    return (uint64_t)(((__uint128_t)ticks * timebase.numer) / timebase.denom);
}

int32_t mp_read_process_metrics(int32_t pid, MPProcessMetrics *result) {
    if (result == NULL) {
        return -1;
    }

    struct rusage_info_v4 usage;
    memset(&usage, 0, sizeof(usage));
    if (proc_pid_rusage(pid, RUSAGE_INFO_V4, (rusage_info_t *)&usage) != 0) {
        return -1;
    }

    result->user_time_ns = mp_mach_ticks_to_ns(usage.ri_user_time);
    result->system_time_ns = mp_mach_ticks_to_ns(usage.ri_system_time);
    result->physical_footprint = usage.ri_phys_footprint;
    result->start_time = usage.ri_proc_start_abstime;
    return 0;
}

int32_t mp_read_process_cwd(int32_t pid, char *buffer, uint32_t size) {
    if (buffer == NULL || size == 0) {
        return -1;
    }
    struct proc_vnodepathinfo info;
    memset(&info, 0, sizeof(info));
    int bytes = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, sizeof(info));
    if (bytes != (int)sizeof(info)) {
        return -1;
    }
    strlcpy(buffer, info.pvi_cdir.vip_path, size);
    return 0;
}
