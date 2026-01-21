#ifndef NEVA_CONGESTION_H_
#define NEVA_CONGESTION_H_

#include "ebpf_kernel.h"

/* Map index 0: packet counter, index 1: threshold. */
#ifndef __uint
#define __uint(name, val) int (*name)[val]
#endif
#ifndef __type
#define __type(name, val) typeof(val) *name
#endif

struct {
    __uint(type, BPF_MAP_TYPE_ARRAY);
    __uint(max_entries, 2);
    __type(key, u32);
    __type(value, u32);
} congestion_reg SEC(".maps");

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
