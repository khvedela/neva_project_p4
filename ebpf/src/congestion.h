#ifndef NEVA_CONGESTION_H_
#define NEVA_CONGESTION_H_

#include "ebpf_kernel.h"

/* Map index 0: packet counter, index 1: threshold. */
struct bpf_map_def SEC("maps") congestion_reg = {
    .type = BPF_MAP_TYPE_ARRAY,
    .key_size = sizeof(u32),
    .value_size = sizeof(u32),
    .max_entries = 2,
};

static __attribute__((always_inline)) void check_congestion(u8 *should_drop) {
    u32 key_counter = 0;
    u32 key_threshold = 1;
    u32 *count = bpf_map_lookup_elem(&congestion_reg, &key_counter);
    u32 *limit = bpf_map_lookup_elem(&congestion_reg, &key_threshold);

    if (count && limit) {
        __sync_fetch_and_add(count, 1);
        if (*count > *limit) {
            *should_drop = 1;
        } else {
            *should_drop = 0;
        }
    } else {
        *should_drop = 0;
    }
}

#endif
