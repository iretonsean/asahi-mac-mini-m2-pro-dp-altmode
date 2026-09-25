/* harness IN.dtb ADT.bin|- "cmdline" OUT.dtb : run the stub fixup exactly as update_fdt() would. */
#include <stdio.h>
#include <stdlib.h>
#include "apple-dcpext-test-shim.h"
static u64 cell64(const void *p, int i) { const fdt32_t *c = p; return (u64)fdt32_to_cpu(c[2*i]) << 32 | fdt32_to_cpu(c[2*i+1]); }
static u8 *adt; static long adt_len; static u64 adt_pa;
const u8 *test_phys_to_ptr(u64 pa) { return pa == adt_pa ? adt : NULL; }
static void *slurp(const char *fn, long *len) {
	FILE *f = fopen(fn, "rb"); if (!f) { perror(fn); exit(2); }
	fseek(f, 0, SEEK_END); *len = ftell(f); rewind(f);
	void *b = malloc(*len ? *len : 1); if (fread(b, 1, *len, f) != (size_t)*len) exit(2); fclose(f); return b;
}
int main(int argc, char **argv) {
	long dlen; void *in = slurp(argv[1], &dlen), *fdt = malloc(0x200000);
	if (argc != 5 || fdt_open_into(in, fdt, 0x200000)) return 2;
	int r = fdt_path_offset(fdt, "/reserved-memory"), n;
	fdt_for_each_subnode(n, fdt, r) {
		const char *l = fdt_getprop(fdt, n, "label", NULL);
		if (l && !strcmp(l, "adt")) { adt_pa = cell64(fdt_getprop(fdt, n, "reg", NULL), 0); }
	}
	if (strcmp(argv[2], "-")) {
		long l; u8 *tmp = slurp(argv[2], &l);
		/* ADT sits in a region exactly as large as the DT's reg says; copy into an exact-size buffer so ASan sees overreads */
		const void *reg = NULL;
		fdt_for_each_subnode(n, fdt, r) { const char *lb = fdt_getprop(fdt, n, "label", NULL); if (lb && !strcmp(lb, "adt")) reg = fdt_getprop(fdt, n, "reg", NULL); }
		adt_len = cell64(reg, 1); adt = calloc(1, adt_len); memcpy(adt, tmp, l < adt_len ? l : adt_len);
	}
	efi_apple_dcpext1_fixup(fdt, argv[3]);
	fdt_pack(fdt);
	FILE *o = fopen(argv[4], "wb"); fwrite(fdt, 1, fdt_totalsize(fdt), o); fclose(o);
	return 0;
}
