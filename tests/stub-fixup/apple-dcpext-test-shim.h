/* Userspace shim so drivers/firmware/efi/libstub/apple-dcpext.c builds against dtc's libfdt. */
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include "libfdt.h"
typedef uint8_t u8; typedef uint32_t u32; typedef unsigned long long u64;
#define SZ_16K 0x4000ULL
#define SZ_8M 0x800000ULL
#define ALIGN(x, a) (((x) + (a) - 1) & ~((u64)(a) - 1))
#define efi_info(...) printf("efi_info: " __VA_ARGS__)
#define efi_err(...) printf("efi_err: " __VA_ARGS__)
const u8 *test_phys_to_ptr(u64 pa);
#define APPLE_DCPEXT_PHYS_TO_PTR(pa) test_phys_to_ptr(pa)
void efi_apple_dcpext1_fixup(void *fdt, const char *cmdline);
