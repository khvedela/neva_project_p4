/* Fichier : ebpf_kernel.h - VERSION CORRIGEE NEVA */
#ifndef BACKENDS_EBPF_RUNTIME_EBPF_KERNEL_H_
#define BACKENDS_EBPF_RUNTIME_EBPF_KERNEL_H_

#include <stddef.h>  // size_t
#include <sys/types.h>  // ssize_t
#include "ebpf_common.h"

/* --- FIX 1 : Définition manuelle des booléens --- */
#ifndef true
#define true 1
#endif
#ifndef false
#define false 0
#endif

/* --- FIX 2 : Définition de la structure bpf_map_def --- */
struct bpf_map_def {
    unsigned int type;
    unsigned int key_size;
    unsigned int value_size;
    unsigned int max_entries;
    unsigned int map_flags;
};

/* --- FIX 3 : Gestion Endianness (incluant 64 bits) --- */
#include <linux/types.h>
#include <linux/swab.h>

#if __BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__
# define bpf_htons(x) __builtin_bswap16(x)
# define bpf_ntohs(x) __builtin_bswap16(x)
# define bpf_htonl(x) __builtin_bswap32(x)
# define bpf_ntohl(x) __builtin_bswap32(x)
# define bpf_cpu_to_be64(x) __builtin_bswap64(x)
# define bpf_be64_to_cpu(x) __builtin_bswap64(x)
#elif __BYTE_ORDER__ == __ORDER_BIG_ENDIAN__
# define bpf_htons(x) (x)
# define bpf_ntohs(x) (x)
# define bpf_htonl(x) (x)
# define bpf_ntohl(x) (x)
# define bpf_cpu_to_be64(x) (x)
# define bpf_be64_to_cpu(x) (x)
#endif

#undef htonl
#undef htons
#define htons(d) bpf_htons(d)
#define htonl(d) bpf_htonl(d)
#define htonll(d) bpf_cpu_to_be64(d)
#define ntohll(x) bpf_be64_to_cpu(x)
#ifndef bpf_htonll
#define bpf_htonll(x) htonll(x)
#endif

#define load_byte(data, b) (*(((u8*)(data)) + (b)))
#define load_half(data, b) bpf_ntohs(*(u16 *)((u8*)(data) + (b)))
#define load_word(data, b) bpf_ntohl(*(u32 *)((u8*)(data) + (b)))
#define load_dword(data, b) bpf_be64_to_cpu(*(u64 *)((u8*)(data) + (b)))

/* --- CONTROL PLANE vs KERNEL DEFINITIONS --- */
#ifdef CONTROL_PLANE
#include "install/libbpf/include/bpf/bpf.h"
#define BPF_USER_MAP_UPDATE_ELEM(index, key, value, flags) bpf_map_update_elem(index, key, value, flags)
#define BPF_OBJ_PIN(table, name) bpf_obj_pin(table, name)
#define BPF_OBJ_GET(name) bpf_obj_get(name)

#else // KERNEL DEFINITIONS

#include <linux/bpf.h>
#include <linux/pkt_cls.h>

/* Helpers manuels */
static void *(*bpf_map_lookup_elem)(void *map, void *key) = (void *) BPF_FUNC_map_lookup_elem;
static int (*bpf_map_update_elem)(void *map, void *key, void *value, unsigned long long flags) = (void *) BPF_FUNC_map_update_elem;

#define MAPS_ELF_SEC ".maps"
#define SK_BUFF struct __sk_buff

/* Macros pour l'enregistrement des tables (compatibilité legacy) */
#define REGISTER_START()
#define REGISTER_END()
#define REGISTER_TABLE(NAME, TYPE, KEY_TYPE, VALUE_TYPE, MAX_ENTRIES) \
struct bpf_map_def SEC("maps") NAME = { \
    .type = TYPE, \
    .key_size = sizeof(KEY_TYPE), \
    .value_size = sizeof(VALUE_TYPE), \
    .max_entries = MAX_ENTRIES, \
};

#endif
#endif