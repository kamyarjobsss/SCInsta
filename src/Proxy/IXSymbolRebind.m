#import "IXSymbolRebind.h"

#import <dlfcn.h>
#import <fcntl.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <mach-o/nlist.h>
#import <mach/mach.h>
#import <mach/vm_map.h>
#import <pthread.h>
#import <stddef.h>
#import <Foundation/Foundation.h>
#import <stdlib.h>
#import <string.h>
#import <sys/mman.h>
#import <sys/stat.h>
#import <unistd.h>

#define IX_REBIND_NAMES 64

#ifndef MH_DYLIB_IN_CACHE
#define MH_DYLIB_IN_CACHE 0x80000000u
#endif

#ifndef S_LAZY_DYLIB_SYMBOL_POINTERS
#define S_LAZY_DYLIB_SYMBOL_POINTERS 0x10
#endif

#ifndef LC_DYLD_CHAINED_FIXUPS
#define LC_DYLD_CHAINED_FIXUPS 0x80000034u
#endif

#define IX_CHAINED_PTR_64 2
#define IX_CHAINED_PTR_64_OFFSET 6
#define IX_CHAINED_PTR_START_NONE 0xFFFF
#define IX_CHAINED_PTR_START_MULTI 0x8000
#define IX_CHAINED_PTR_START_LAST 0x8000

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
    if (kr == KERN_SUCCESS) return 1;
    kr = vm_protect(mach_task_self(), start, end - start, FALSE, VM_PROT_READ | VM_PROT_WRITE);
    return kr == KERN_SUCCESS;
}

static int IXPointerSection(const struct section_64 *sect) {
    if (!sect) return 0;
    if (strncmp(sect->sectname, "__objc", 6) == 0) return 0;
    if (strcmp(sect->sectname, "__got") == 0 || strcmp(sect->sectname, "__la_symbol_ptr") == 0 ||
        strcmp(sect->sectname, "__nl_symbol_ptr") == 0 || strcmp(sect->sectname, "__auth_got") == 0 ||
        strcmp(sect->sectname, "__auth_ptr") == 0) {
        return 1;
    }
    uint32_t type = sect->flags & SECTION_TYPE;
    return type == S_LAZY_SYMBOL_POINTERS || type == S_NON_LAZY_SYMBOL_POINTERS || type == S_LAZY_DYLIB_SYMBOL_POINTERS;
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

struct ix_chained_fixups_header {
    uint32_t fixups_version;
    uint32_t starts_offset;
    uint32_t imports_offset;
    uint32_t symbols_offset;
    uint32_t imports_count;
    uint32_t imports_format;
    uint32_t symbols_format;
};

struct ix_chained_starts_image {
    uint32_t seg_count;
    uint32_t seg_info_offset[];
};

struct ix_chained_starts_seg {
    uint32_t size;
    uint16_t page_size;
    uint16_t pointer_format;
    uint64_t segment_offset;
    uint32_t max_valid_pointer;
    uint16_t page_count;
    uint16_t page_start[];
};

static uint32_t IXSwap32(uint32_t value) {
    return (value << 24) | ((value << 8) & 0x00FF0000u) | ((value >> 8) & 0x0000FF00u) | (value >> 24);
}

static const char *IXChainedSymbol(const uint8_t *imports, uint32_t importsCount, uint32_t format, const char *symbols, uint32_t ordinal) {
    if (!imports || !symbols || ordinal >= importsCount) return NULL;
    uint32_t nameOffset = 0;
    if (format == 1 || format == 2) {
        uint32_t stride = format == 2 ? 8u : 4u;
        uint32_t word = 0;
        memcpy(&word, imports + (size_t)ordinal * stride, sizeof(word));
        nameOffset = word >> 9;
    } else if (format == 3) {
        uint64_t word = 0;
        memcpy(&word, imports + (size_t)ordinal * 16u, sizeof(word));
        nameOffset = (uint32_t)((word >> 17) & 0xffffffffu);
    } else {
        return NULL;
    }
    return symbols + nameOffset;
}

static int IXRebindChained(const struct mach_header *header, const char *path,
                           const char *const *names, void *const *replacements, unsigned count, int remember) {
    if (!header || !path || header->magic != MH_MAGIC_64) return 0;
    if (header->flags & MH_DYLIB_IN_CACHE) return 0;
    if (strncmp(path, "/usr/lib/", 9) == 0 || strncmp(path, "/System/", 8) == 0) return 0;

    int fd = open(path, O_RDONLY);
    if (fd < 0) return 0;
    struct stat st;
    if (fstat(fd, &st) != 0 || st.st_size < (off_t)sizeof(struct mach_header_64)) {
        close(fd);
        return 0;
    }
    void *mapped = mmap(NULL, (size_t)st.st_size, PROT_READ, MAP_PRIVATE, fd, 0);
    close(fd);
    if (mapped == MAP_FAILED) return 0;

    const uint8_t *base = mapped;
    size_t size = (size_t)st.st_size;
    uint32_t magic = 0;
    memcpy(&magic, base, sizeof(magic));
    if (magic == 0xBEBAFECAu || magic == 0xCAFEBABEu) {
        int swap = magic == 0xBEBAFECAu;
        uint32_t nfat = 0;
        memcpy(&nfat, base + 4, sizeof(nfat));
        if (swap) nfat = IXSwap32(nfat);
        const uint8_t *slice = NULL;
        size_t sliceSize = 0;
        for (uint32_t i = 0; i < nfat && 8 + ((size_t)i + 1) * 20 <= size; i++) {
            uint32_t cputype = 0, offset = 0, sliceLen = 0;
            const uint8_t *arch = base + 8 + (size_t)i * 20;
            memcpy(&cputype, arch, 4);
            memcpy(&offset, arch + 8, 4);
            memcpy(&sliceLen, arch + 12, 4);
            if (swap) {
                cputype = IXSwap32(cputype);
                offset = IXSwap32(offset);
                sliceLen = IXSwap32(sliceLen);
            }
            if (cputype == 0x0100000Cu && (size_t)offset + sliceLen <= size) {
                slice = base + offset;
                sliceSize = sliceLen;
                break;
            }
        }
        if (!slice) {
            munmap(mapped, size);
            return 0;
        }
        base = slice;
        size = sliceSize;
    }

    uint32_t thinMagic = 0;
    memcpy(&thinMagic, base, sizeof(thinMagic));
    if (thinMagic != MH_MAGIC_64 || size < sizeof(struct mach_header_64)) {
        munmap(mapped, (size_t)st.st_size);
        return 0;
    }

    struct mach_header_64 fileHeader;
    memcpy(&fileHeader, base, sizeof(fileHeader));
    const struct linkedit_data_command *chained = NULL;
    struct segment_command_64 segs[16];
    unsigned segCount = 0;
    uint64_t textVMAddr = 0;
    int sawText = 0;
    const uint8_t *cursor = base + sizeof(struct mach_header_64);
    const uint8_t *end = base + size;
    for (uint32_t i = 0; i < fileHeader.ncmds && cursor + sizeof(struct load_command) <= end; i++) {
        struct load_command cmd;
        memcpy(&cmd, cursor, sizeof(cmd));
        if (cmd.cmdsize < sizeof(cmd) || cursor + cmd.cmdsize > end) break;
        if (cmd.cmd == LC_SEGMENT_64 && cmd.cmdsize >= sizeof(struct segment_command_64) && segCount < 16) {
            memcpy(&segs[segCount], cursor, sizeof(segs[0]));
            if (strcmp(segs[segCount].segname, "__TEXT") == 0) {
                textVMAddr = segs[segCount].vmaddr;
                sawText = 1;
            }
            segCount++;
        } else if (cmd.cmd == LC_DYLD_CHAINED_FIXUPS && cmd.cmdsize >= sizeof(struct linkedit_data_command)) {
            chained = (const struct linkedit_data_command *)cursor;
        }
        cursor += cmd.cmdsize;
    }
    struct linkedit_data_command chainedCopy;
    if (chained) memcpy(&chainedCopy, chained, sizeof(chainedCopy));
    if (!chained || !sawText || chainedCopy.dataoff + sizeof(struct ix_chained_fixups_header) > size) {
        munmap(mapped, (size_t)st.st_size);
        return 0;
    }

    struct ix_chained_fixups_header fixups;
    memcpy(&fixups, base + chainedCopy.dataoff, sizeof(fixups));
    if (fixups.symbols_format != 0 || fixups.imports_count == 0 || fixups.imports_count > 200000) {
        munmap(mapped, (size_t)st.st_size);
        return 0;
    }
    uint32_t blob = chainedCopy.dataoff;
    if (fixups.starts_offset >= chainedCopy.datasize || fixups.imports_offset >= chainedCopy.datasize ||
        fixups.symbols_offset >= chainedCopy.datasize) {
        munmap(mapped, (size_t)st.st_size);
        return 0;
    }
    const uint8_t *starts = base + blob + fixups.starts_offset;
    const uint8_t *imports = base + blob + fixups.imports_offset;
    const char *symbols = (const char *)(base + blob + fixups.symbols_offset);
    if (starts + sizeof(uint32_t) > base + size) {
        munmap(mapped, (size_t)st.st_size);
        return 0;
    }
    uint32_t imageSegs = 0;
    memcpy(&imageSegs, starts, sizeof(imageSegs));
    if (imageSegs == 0 || imageSegs > 64) {
        munmap(mapped, (size_t)st.st_size);
        return 0;
    }

    int patched = 0;
    for (uint32_t segIndex = 0; segIndex < imageSegs; segIndex++) {
        if (starts + sizeof(uint32_t) * (segIndex + 2) > base + size) break;
        uint32_t infoOff = 0;
        memcpy(&infoOff, starts + sizeof(uint32_t) * (segIndex + 1), sizeof(infoOff));
        if (infoOff == 0) continue;
        const uint8_t *info = starts + infoOff;
        if (info + sizeof(struct ix_chained_starts_seg) > base + size) continue;
        struct ix_chained_starts_seg segInfo;
        memcpy(&segInfo, info, sizeof(segInfo));
        if (segInfo.pointer_format != IX_CHAINED_PTR_64 && segInfo.pointer_format != IX_CHAINED_PTR_64_OFFSET) continue;
        if (segInfo.page_size < 0x1000 || segInfo.page_count > 65535) continue;
        const uint8_t *pageStarts = info + offsetof(struct ix_chained_starts_seg, page_start);
        if (pageStarts + sizeof(uint16_t) * segInfo.page_count > base + size) continue;

        for (uint16_t page = 0; page < segInfo.page_count; page++) {
            uint16_t start = 0;
            memcpy(&start, pageStarts + sizeof(uint16_t) * page, sizeof(start));
            uint16_t startsOnPage[64];
            unsigned startCount = 0;
            if (start == IX_CHAINED_PTR_START_NONE) continue;
            if (start & IX_CHAINED_PTR_START_MULTI) {
                uint16_t overflow = start & (uint16_t)~IX_CHAINED_PTR_START_MULTI;
                while (startCount < 64) {
                    if (pageStarts + sizeof(uint16_t) * (overflow + 1) > base + size) break;
                    uint16_t entry = 0;
                    memcpy(&entry, pageStarts + sizeof(uint16_t) * overflow, sizeof(entry));
                    overflow++;
                    startsOnPage[startCount++] = entry & (uint16_t)~IX_CHAINED_PTR_START_LAST;
                    if (entry & IX_CHAINED_PTR_START_LAST) break;
                }
            } else {
                startsOnPage[startCount++] = start;
            }

            for (unsigned chain = 0; chain < startCount; chain++) {
                uint32_t offset = startsOnPage[chain];
                for (int step = 0; step < 8192; step++) {
                    uint64_t vmAddr = textVMAddr + segInfo.segment_offset + (uint64_t)page * segInfo.page_size + offset;
                    const struct segment_command_64 *owner = NULL;
                    for (unsigned s = 0; s < segCount; s++) {
                        if (vmAddr >= segs[s].vmaddr && vmAddr < segs[s].vmaddr + segs[s].vmsize) {
                            owner = &segs[s];
                            break;
                        }
                    }
                    if (!owner) break;
                    uint64_t fileOff = owner->fileoff + (vmAddr - owner->vmaddr);
                    if (fileOff + sizeof(uint64_t) > size) break;
                    uint64_t raw = 0;
                    memcpy(&raw, base + fileOff, sizeof(raw));
                    int isBind = (int)((raw >> 63) & 1u);
                    uint32_t next = (uint32_t)((raw >> 51) & 0xFFFu);
                    if (isBind) {
                        uint32_t ordinal = (uint32_t)(raw & 0xFFFFFFu);
                        const char *symbol = IXChainedSymbol(imports, fixups.imports_count, fixups.imports_format, symbols, ordinal);
                        unsigned which = 0;
                        if (symbol && symbol + 1 < (const char *)base + size && IXNameMatch(symbol, names, count, &which)) {
                            void *replacement = replacements[which];
                            void **slot = (void **)((uintptr_t)header + (uintptr_t)(segInfo.segment_offset + (uint64_t)page * segInfo.page_size + offset));
                            if (replacement && slot) {
                                void *existing = *slot;
                                if (IXStrip(existing) != replacement) {
                                    if (IXMakeDataWritable(slot, sizeof(void *))) {
                                        if (!remember || IXRemember(slot, existing)) {
                                            *slot = IXSignLike(slot, existing, replacement);
                                            patched++;
                                        }
                                    }
                                }
                            }
                        }
                    }
                    if (next == 0) break;
                    offset += next * 4u;
                }
            }
        }
    }
    munmap(mapped, (size_t)st.st_size);
    return patched;
}

static int IXRebindImage(const struct mach_header *header, intptr_t slide, const char *path,
                         const char *const *names, void *const *replacements, unsigned count, int remember) {
    if (!header || header->magic != MH_MAGIC_64) return 0;
    // IXRayCore must keep the real libc symbols. SCInsta too: the handshake
    // calls connect/send/recv/poll, and rebinding this image would recurse.
    if (path && (strstr(path, "IXRayCore") || strstr(path, "SCInsta"))) return 0;

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
                if (!IXPointerSection(sect)) continue;
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
    patched += IXRebindChained(header, path, names, replacements, count, remember);
    return patched;
}

static const char *ix_saved_names[IX_REBIND_NAMES];
static void *ix_saved_repl[IX_REBIND_NAMES];
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
    ix_saved_count = count > IX_REBIND_NAMES ? IX_REBIND_NAMES : count;
    for (unsigned i = 0; i < ix_saved_count; i++) {
        ix_saved_names[i] = names[i];
        ix_saved_repl[i] = replacements[i];
    }
    ix_rebind_live = 1;
    int patched = 0;
    int frameworkPatches = -1;
    uint32_t images = _dyld_image_count();
    for (uint32_t i = 0; i < images; i++) {
        const char *path = _dyld_get_image_name(i);
        int imagePatches = IXRebindImage(_dyld_get_image_header(i), _dyld_get_image_vmaddr_slide(i), path,
                                         names, replacements, count, 1);
        patched += imagePatches;
        if (path && strstr(path, "FBSharedFramework")) frameworkPatches = imagePatches;
    }
    int registerCallback = 0;
    if (!ix_image_callback) {
        ix_image_callback = 1;
        registerCallback = 1;
    }
    pthread_mutex_unlock(&ix_rebind_mu);
    if (frameworkPatches >= 0) {
        NSLog(@"[InstagramX] FBSharedFramework rebind patched %d slots", frameworkPatches);
    }
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
