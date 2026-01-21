/* Fichier : ebpf_common.h */
#ifndef _EBPF_COMMON_H_
#define _EBPF_COMMON_H_

typedef unsigned char u8;
typedef unsigned short u16;
typedef unsigned int u32;
typedef unsigned long long u64;

#define SEC(NAME) __attribute__((section(NAME), used))

#endif