#import "IXSymbolRebind.h"

#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <mach-o/nlist.h>
#import <mach/mach.h>
#import <mach/vm_map.h>
#import <pthread.h>
#import <stdlib.h>
#import <string.h>
#import <unistd.h>

#ifndef VM_PROT_COPY
#define VM_PROT_COPY ((vm_prot_t)0x10)
#endif

#if __has_feature(ptrauth_calls)
#import <ptrauth.h>
#endif

typedef struct {
    void **slot;
    void *original;
} IXReboundSlot;

static IXReboundSlot *ix_slots = NULL;
static unsigned ix_slot_count = 0;
static unsigned ix_slot_cap = 0;
static pthread_mutex_t ix_rebind_mu = PTHREAD_MUTEX_INITIALIZER;

static void *IXStrip(void *pointer) {
#if __has_feature(ptrauth_calls)
    return ptrauth_strip(pointer, ptrauth_key_asia);
#else
    return pointer;
#endif
}

static void *IXSignLike(void **slot, void *existing, void *replacement) {
#if __has_feature(ptrauth_calls)
    if (IXStrip(existing) != existing) {
        return ptrauth_sign_unauthenticated(replacement, ptrauth_key_asia, slot);
    }
#else
    (void)slot;
    (void)existing;
#endif
    return replacement;
}

static int IXMakeDataWritable(void *address, size_t size) {
    if (!address || size == 0) return 0;
    long rawPage = getpagesize();
    vm_size_t page = rawPage > 0 ? (vm_size_t)rawPage : 16384;
    vm_address_t start = (vm_address_t)address & ~((vm_address_t)page - 1);
    vm_address_t end = ((vm_address_t)address + size + page - 1) & ~((vm_address_t)page - 1);
    kern_return_t kr = vm_protect(mach_task_self(), start, end - start, FALSE,
                                  VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
    return kr == KERN_SUCCESS;
}

static int IXRemember(void **slot, void *original) {
    if (ix_slot_count == ix_slot_cap) {
        unsigned cap = ix_slot_cap ? ix_slot_cap * 2 : 64;
        if (cap > 8192) return 0;
        IXReboundSlot *grown = realloc(ix_slots, cap * sizeof(*grown));
        if (!grown) return 0;
        ix_slots = grown;
        ix_slot_cap = cap;
    }
    ix_slots[ix_slot_count].slot = slot;
    ix_slots[ix_slot_count].original = original;
    ix_slot_count++;
    return 1;
}

static int IXNameMatch(const char *symbol, const char *const *names, unsigned count, unsigned *index) {
    if (!symbol || symbol[0] != '_') return 0;
    for (unsigned i = 0; i < count; i++) {
        if (names[i] && strcmp(symbol + 1, names[i]) == 0) {
            *index = i;
            return 1;
        }
    }
    return 0;
}

static int IXRebindImage(const struct mach_header *header, intptr_t slide, const char *path,
                         const char *const *names, void *const *replacements, unsigned count, int remember) {
    if (!header || header->magic != MH_MAGIC_64) return 0;
    if (path && strstr(path, "IXRayCore")) return 0;

    const struct segment_command_64 *linkedit = NULL;
    const struct symtab_command *symtabCmd = NULL;
    const struct dysymtab_command *dysymtab = NULL;
    const uint8_t *cursor = (const uint8_t *)header + sizeof(struct mach_header_64);
    for (uint32_t i = 0; i < header->ncmds; i++) {
        const struct load_command *cmd = (const struct load_command *)cursor;
        if (cmd->cmdsize < sizeof(struct load_command) || cursor + cmd->cmdsize > (const uint8_t *)header + 0x100000) {
            break;
        }
        if (cmd->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *seg = (const struct segment_command_64 *)cmd;
            if (strcmp(seg->segname, SEG_LINKEDIT) == 0) linkedit = seg;
        } else if (cmd->cmd == LC_SYMTAB) {
            symtabCmd = (const struct symtab_command *)cmd;
        } else if (cmd->cmd == LC_DYSYMTAB) {
            dysymtab = (const struct dysymtab_command *)cmd;
        }
        cursor += cmd->cmdsize;
    }
    if (!linkedit || !symtabCmd || !dysymtab || dysymtab->nindirectsyms == 0) return 0;

    uintptr_t linkeditBase = (uintptr_t)slide + linkedit->vmaddr - linkedit->fileoff;
    const struct nlist_64 *symtab = (const struct nlist_64 *)(linkeditBase + symtabCmd->symoff);
    const char *strtab = (const char *)(linkeditBase + symtabCmd->stroff);
    const uint32_t *indirect = (const uint32_t *)(linkeditBase + dysymtab->indirectsymoff);
    int patched = 0;

    cursor = (const uint8_t *)header + sizeof(struct mach_header_64);
    for (uint32_t i = 0; i < header->ncmds; i++) {
        const struct load_command *cmd = (const struct load_command *)cursor;
        if (cmd->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *seg = (const struct segment_command_64 *)cmd;
            if (strcmp(seg->segname, "__TEXT") == 0) {
                cursor += cmd->cmdsize;
                continue;
            }
            const struct section_64 *sect = (const struct section_64 *)(seg + 1);
            for (uint32_t s = 0; s < seg->nsects; s++, sect++) {
                uint32_t type = sect->flags & SECTION_TYPE;
                if (type != S_LAZY_SYMBOL_POINTERS && type != S_NON_LAZY_SYMBOL_POINTERS) continue;
                if (strcmp(sect->segname, "__TEXT") == 0) continue;
                if (sect->size < sizeof(void *) || sect->reserved1 >= dysymtab->nindirectsyms) continue;

                void **slots = (void **)((uintptr_t)slide + sect->addr);
                uint32_t nslots = (uint32_t)(sect->size / sizeof(void *));
                uint32_t remain = dysymtab->nindirectsyms - sect->reserved1;
                if (nslots > remain) nslots = remain;
                int writable = 0;

                for (uint32_t index = 0; index < nslots; index++) {
                    uint32_t symbolIndex = indirect[sect->reserved1 + index];
                    if (symbolIndex == INDIRECT_SYMBOL_ABS || symbolIndex == INDIRECT_SYMBOL_LOCAL ||
                        symbolIndex == (INDIRECT_SYMBOL_LOCAL | INDIRECT_SYMBOL_ABS)) {
                        continue;
                    }
                    if (symbolIndex >= symtabCmd->nsyms) continue;
                    uint32_t strx = symtab[symbolIndex].n_un.n_strx;
                    if (strx == 0 || strx >= symtabCmd->strsize) continue;
                    unsigned which = 0;
                    if (!IXNameMatch(strtab + strx, names, count, &which)) continue;
                    void *replacement = replacements[which];
                    if (!replacement) continue;
                    void *existing = slots[index];
                    if (IXStrip(existing) == replacement) continue;
                    if (!writable) {
                        if (!IXMakeDataWritable(slots, sect->size)) break;
                        writable = 1;
                    }
                    if (remember && !IXRemember(&slots[index], existing)) return patched;
                    slots[index] = IXSignLike(&slots[index], existing, replacement);
                    patched++;
                }
            }
        }
        cursor += cmd->cmdsize;
    }
    return patched;
}

static const char *ix_saved_names[8];
static void *ix_saved_repl[8];
static unsigned ix_saved_count = 0;
static int ix_rebind_live = 0;
static int ix_image_callback = 0;
static const char *ix_perm_names[4];
static void *ix_perm_repl[4];
static unsigned ix_perm_count = 0;

static void IXOnNewImage(const struct mach_header *header, intptr_t slide) {
    pthread_mutex_lock(&ix_rebind_mu);
    const char *path = NULL;
    uint32_t images = _dyld_image_count();
    for (uint32_t i = 0; i < images; i++) {
        if (_dyld_get_image_header(i) == header) {
            path = _dyld_get_image_name(i);
            break;
        }
    }
    if (ix_rebind_live && ix_saved_count) {
        IXRebindImage(header, slide, path, ix_saved_names, ix_saved_repl, ix_saved_count, 1);
    }
    if (ix_perm_count) {
        IXRebindImage(header, slide, path, ix_perm_names, ix_perm_repl, ix_perm_count, 0);
    }
    pthread_mutex_unlock(&ix_rebind_mu);
}

int IXSymbolRebindSlots(const char *const *names, void *const *replacements, unsigned count) {
    if (!names || !replacements || count == 0) return 0;
    pthread_mutex_lock(&ix_rebind_mu);
    ix_saved_count = count > 8 ? 8 : count;
    for (unsigned i = 0; i < ix_saved_count; i++) {
        ix_saved_names[i] = names[i];
        ix_saved_repl[i] = replacements[i];
    }
    ix_rebind_live = 1;
    int patched = 0;
    uint32_t images = _dyld_image_count();
    for (uint32_t i = 0; i < images; i++) {
        const char *path = _dyld_get_image_name(i);
        patched += IXRebindImage(_dyld_get_image_header(i), _dyld_get_image_vmaddr_slide(i), path,
                                 names, replacements, count, 1);
    }
    int registerCallback = 0;
    if (!ix_image_callback) {
        ix_image_callback = 1;
        registerCallback = 1;
    }
    pthread_mutex_unlock(&ix_rebind_mu);
    // Registration invokes the callback for images already loaded. That must
    // happen without ix_rebind_mu held, because the callback takes the same lock.
    if (registerCallback) _dyld_register_func_for_add_image(IXOnNewImage);
    return patched;
}

int IXSymbolRebindPermanent(const char *const *names, void *const *replacements, unsigned count) {
    if (!names || !replacements || count == 0) return 0;
    pthread_mutex_lock(&ix_rebind_mu);
    unsigned kept = count > 4 ? 4 : count;
    for (unsigned i = 0; i < kept; i++) {
        int found = 0;
        for (unsigned j = 0; j < ix_perm_count; j++) {
            if (ix_perm_names[j] && names[i] && strcmp(ix_perm_names[j], names[i]) == 0) {
                ix_perm_repl[j] = replacements[i];
                found = 1;
                break;
            }
        }
        if (!found && ix_perm_count < 4) {
            ix_perm_names[ix_perm_count] = names[i];
            ix_perm_repl[ix_perm_count] = replacements[i];
            ix_perm_count++;
        }
    }
    int patched = 0;
    uint32_t images = _dyld_image_count();
    for (uint32_t i = 0; i < images; i++) {
        const char *path = _dyld_get_image_name(i);
        patched += IXRebindImage(_dyld_get_image_header(i), _dyld_get_image_vmaddr_slide(i), path,
                                 ix_perm_names, ix_perm_repl, ix_perm_count, 0);
    }
    int registerCallback = 0;
    if (!ix_image_callback) {
        ix_image_callback = 1;
        registerCallback = 1;
    }
    pthread_mutex_unlock(&ix_rebind_mu);
    if (registerCallback) _dyld_register_func_for_add_image(IXOnNewImage);
    return patched;
}

void IXSymbolRebindRestore(void) {
    pthread_mutex_lock(&ix_rebind_mu);
    ix_rebind_live = 0;
    for (unsigned i = 0; i < ix_slot_count; i++) {
        void **slot = ix_slots[i].slot;
        if (!slot) continue;
        if (!IXMakeDataWritable(slot, sizeof(void *))) continue;
        *slot = ix_slots[i].original;
    }
    free(ix_slots);
    ix_slots = NULL;
    ix_slot_count = 0;
    ix_slot_cap = 0;
    pthread_mutex_unlock(&ix_rebind_mu);
}
