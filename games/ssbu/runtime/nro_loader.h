#pragma once
#include <stddef.h>
#include <stdint.h>

typedef struct {
    const char *name;
    const char *source_name;
    uint32_t image_size;
    uint32_t bss_size;
    uint8_t sha256[32];
} ssbu_nro_catalog_entry;

typedef struct {
    uint32_t image_size;
    uint8_t sha256[32];
} ssbu_nrr_catalog_entry;

typedef struct {
    const char *name;
    uint32_t module_index;
    uint32_t type;
    uint64_t offset;
} ssbu_nro_export_entry;

extern const ssbu_nro_catalog_entry g_ssbu_nro_catalog[];
extern const unsigned g_ssbu_nro_catalog_count;
extern const ssbu_nrr_catalog_entry g_ssbu_nrr_catalog[];
extern const unsigned g_ssbu_nrr_catalog_count;
extern const ssbu_nro_export_entry g_ssbu_nro_exports[];
extern const unsigned g_ssbu_nro_export_count;

void runtime_nro_set_rewritten_dir(const char *dir);
int runtime_nro_supported(void);
uintptr_t runtime_nro_defer_import(void *slot, const char *name, unsigned kind, int64_t addend);
void *runtime_nro_symbol(const char *name);
int runtime_nro_describe_address(uint64_t a, const char **name, uint64_t *off);
int runtime_nro_module_permission(uint64_t address, uint64_t size, unsigned permission, uint64_t *result_out);
int runtime_nro_module_lock_permission(uint64_t address, uint64_t size, unsigned mask, unsigned attribute, uint64_t *result_out);
int runtime_nro_module_query(uint64_t address, uint64_t *base, uint64_t *size, unsigned *state, unsigned *permission, unsigned *attribute);
uint64_t runtime_nro_image_bytes(void);
void *runtime_ro_override(const char *name);

