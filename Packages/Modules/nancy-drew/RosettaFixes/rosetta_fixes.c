// rosetta_fixes.c — a proxy comdlg32.dll that makes a Nancy Drew game run at
// speed under Rosetta 2. regenerate.sh builds it into the nancy-drew module's
// assets/rosetta-fixes/comdlg32.dll; DO nancy-drew.rosetta-fixes puts it in
// the game's folder and makes the game load it before Wine's own comdlg32.
// docs/modules.md#rosetta-fixes has why.
//
// The games' maths is compiled for the x87 floating-point unit, which Rosetta
// has no hardware to translate to: it runs every x87 instruction in software,
// many times slower than an Intel Mac did. Two places where that turned a
// scene into a slideshow (Waverly's common room, snow behind its windows,
// at about a frame every two seconds) are fixed here, each found by its
// bytes in the game's code when the DLL loads:
//
// 1. Sound. The games decode their sounds (.HIS files holding Ogg Vorbis)
//    with a copy of libvorbisfile linked into the .exe. Its four entry
//    points are pointed at libogg and libvorbis built for SSE2, which Rosetta
//    runs about as fast as native code. libvorbisfile 1.3.7's OggVorbis_File
//    is laid out exactly as the games' is (0x2d0 bytes; os at 0x78, vd at
//    0x1e0, vb at 0x250), so the game can go on reading its fields; its own
//    Vorbis code is never called again, as those four are all it uses.
// 2. The particle system's catch-up (below, at particle_pattern).
//
// Steam's copies are encrypted until they start (Steam's DRM), so for them
// the patterns are looked for once the game's own code first runs (below, at
// deferred_GetCommandLineA). A game whose .exe doesn't match a fix's patterns
// exactly once is left without that fix, so it plays as it did. SECOND_CHANCE_ROSETTA_FIXES=0
// leaves every game alone.
//
// Every comdlg32 function a game might import is passed on to Wine's own,
// loaded from the system folder the first time one is called.

#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <vorbis/vorbisfile.h>

// ---------------------------------------------------------------------------
// Logging: one line per event, through Wine's own debug output, which goes
// to the wrapp's log (a game has no stderr of its own: it's a GUI program).
// Outside Wine, OutputDebugString.

static void say(const char *format, ...) {
    static int (__cdecl *wine_output)(const char *);
    static BOOL looked;
    if (!looked) {
        wine_output = (int (__cdecl *)(const char *))(void *)GetProcAddress(GetModuleHandleA("ntdll.dll"),
                                                                              "__wine_dbg_output");
        looked = TRUE;
    }
    char line[512];
    va_list args;
    va_start(args, format);
    int length = snprintf(line, sizeof line, "[rosetta-fixes] ");
    vsnprintf(line + length, sizeof line - length - 1, format, args);
    va_end(args);
    strcat(line, "\n");
    if (wine_output) wine_output(line);
    else OutputDebugStringA(line);
}

#ifdef ROSETTA_FIXES_STATS
// For experiments: calls and time in each entry point, every two seconds.
static volatile LONG particle_most, particle_capped, particle_warmups;
static LONGLONG stat_calls[4], stat_ticks[4], stat_bytes, stat_last, stat_frequency;
static void stat(int which, LONGLONG start, long bytes) {
    LARGE_INTEGER now;
    QueryPerformanceCounter(&now);
    stat_calls[which]++;
    stat_ticks[which] += now.QuadPart - start;
    if (bytes > 0) stat_bytes += bytes;
    if (!stat_frequency) {
        LARGE_INTEGER f;
        QueryPerformanceFrequency(&f);
        stat_frequency = f.QuadPart;
        stat_last = now.QuadPart;
    }
    if (now.QuadPart - stat_last > 2 * stat_frequency) {
        double ms = 1000.0 / stat_frequency;
        say("stats: open %lld (%.0f ms), clear %lld (%.0f ms), seek %lld (%.0f ms), read %lld (%.0f ms, %lld bytes)",
            stat_calls[0], stat_ticks[0] * ms, stat_calls[1], stat_ticks[1] * ms, stat_calls[2], stat_ticks[2] * ms,
            stat_calls[3], stat_ticks[3] * ms, stat_bytes);
        say("stats: particle steps due at most %ld, capped %ld times, warm-ups run whole %ld", particle_most,
            particle_capped, particle_warmups);
        particle_most = particle_capped = particle_warmups = 0;
        memset(stat_calls, 0, sizeof stat_calls);
        memset(stat_ticks, 0, sizeof stat_ticks);
        stat_bytes = 0;
        stat_last = now.QuadPart;
    }
}
#define STAT_START LARGE_INTEGER start; QueryPerformanceCounter(&start)
#define STAT(which, bytes) stat(which, start.QuadPart, bytes)
#else
#define STAT_START
#define STAT(which, bytes)
#endif

// ---------------------------------------------------------------------------
// The game's entry points, each in the calling convention its compiler gave
// it (whole-program optimisation moved some arguments into registers).

// The game's C runtime's stdio, which ov_open reads a FILE * with: the game
// opened the FILE with its own runtime, so only its own can read it.
static ov_callbacks game_stdio;

// int ov_open(FILE *f, OggVorbis_File *vf): cdecl, the game's ov_open
// without its initial bytes (always none).
static int __cdecl fast_ov_open(void *file, OggVorbis_File *vf) {
    STAT_START;
    int result = ov_open_callbacks(file, vf, NULL, 0, game_stdio);
    STAT(0, 0);
    return result;
}

// int ov_clear(OggVorbis_File *vf), the file in edi.
__attribute__((used)) int __cdecl fast_ov_clear(OggVorbis_File *vf) {
    STAT_START;
    int result = ov_clear(vf);
    STAT(1, 0);
    return result;
}
__asm__(
    ".text\n"
    "_hook_ov_clear:\n"
    "    pushl %edi\n"
    "    call _fast_ov_clear\n"
    "    addl $4, %esp\n"
    "    ret\n");

// long ov_read(OggVorbis_File *vf, char *buffer, int length, int bigendianp,
// int word, int sgned, int *bitstream): vf, length, word and bitstream on the
// stack, the buffer in ecx, sgned in eax; bigendianp is always 0.
__attribute__((used)) long __cdecl fast_ov_read(OggVorbis_File *vf, char *buffer, int length, int word, int sgned,
                                                      int *bitstream) {
    STAT_START;
    long result = ov_read(vf, buffer, length, 0, word, sgned, bitstream);
    STAT(3, result);
    return result;
}
__asm__(
    ".text\n"
    "_hook_ov_read:\n"
    "    pushl %ebp\n"
    "    movl %esp, %ebp\n"
    "    pushl 0x14(%ebp)\n"   // bitstream
    "    pushl %eax\n"         // sgned
    "    pushl 0x10(%ebp)\n"   // word
    "    pushl 0x0c(%ebp)\n"   // length
    "    pushl %ecx\n"         // buffer
    "    pushl 0x08(%ebp)\n"   // vf
    "    call _fast_ov_read\n"
    "    leave\n"
    "    ret\n");

// int ov_raw_seek(OggVorbis_File *vf, ogg_int64_t pos): cdecl, as libvorbisfile's.
static int __cdecl fast_ov_raw_seek(OggVorbis_File *vf, ogg_int64_t pos) {
    STAT_START;
    int result = ov_raw_seek(vf, pos);
    STAT(2, 0);
    return result;
}

extern char hook_ov_clear[], hook_ov_read[];

// ---------------------------------------------------------------------------
// Finding them: each function's opening bytes, ?? for an address that
// differs from one build to the next.

typedef struct {
    const char *name;
    const char *pattern;
    BYTE *found;
} Entry;

enum { OV_OPEN, OV_CLEAR, OV_RAW_SEEK, OV_READ, ENTRY_COUNT };

static Entry entries[ENTRY_COUNT] = {
    // Builds its stdio callbacks (fread, fseek, fclose, ftell) on the stack
    // and calls ov_open_callbacks.
    [OV_OPEN] = {"ov_open",
        "51 56 57 83 EC 10 8B C4 B9 ?? ?? ?? ?? 89 08 BA ?? ?? ?? ?? 89 50 04 BE ?? ?? ?? ?? 89 70 08 "
        "8B 74 24 24 BF ?? ?? ?? ?? 89 78 0C 8B 44 24 20 50 E8"},
    // vorbis_block_clear(&vf->vb), vorbis_dsp_clear(&vf->vd), ogg_stream_clear(&vf->os).
    [OV_CLEAR] = {"ov_clear",
        "51 53 33 DB 3B FB 0F 84 ?? ?? ?? ?? 8D 87 50 02 00 00 56 50 E8 ?? ?? ?? ?? 8D 8F E0 01 00 00 "
        "51 E8 ?? ?? ?? ?? 83 C4 08 8D 77 78 E8"},
    // ready_state < OPENED, or not seekable: OV_ENOSEEK (-138).
    [OV_RAW_SEEK] = {"ov_raw_seek",
        "55 8B EC 83 E4 F8 81 EC AC 01 00 00 A1 ?? ?? ?? ?? 33 C4 89 84 24 A8 01 00 00 53 56 57 "
        "8B 7D 08 83 7F 58 02 0F 8C ?? ?? ?? ?? 83 7F 04 00 75 ?? B8 76 FF FF FF"},
    // sgned (eax) to ebx, the buffer (ecx) to edi; ready_state < OPENED: OV_EINVAL (-131).
    [OV_READ] = {"ov_read",
        "83 EC 2C 53 55 8B 6C 24 40 56 57 8B D8 8B F9 E8 ?? ?? ?? ?? 8B 74 24 40 83 7E 58 02 "
        "89 44 24 24 7D ?? B8 7D FF FF FF"},
};

// The pattern as bytes, -1 for ??. Returns its length.
static int parse(const char *pattern, int *out, int max) {
    int n = 0;
    for (const char *p = pattern; *p && n < max;) {
        if (*p == ' ') { p++; continue; }
        out[n++] = p[0] == '?' ? -1 : (int)strtol((char[]){p[0], p[1], 0}, NULL, 16);
        p += 2;
    }
    return n;
}

// How many times the pattern is in [start, end), the first in *found.
static int find(BYTE *start, BYTE *end, const char *pattern, BYTE **found) {
    int bytes[96];
    int length = parse(pattern, bytes, 96);
    int count = 0;
    for (BYTE *at = start; at + length <= end; at++) {
        int i = 0;
        while (i < length && (bytes[i] < 0 || at[i] == bytes[i])) i++;
        if (i == length) {
            if (count++ == 0) *found = at;
        }
    }
    return count;
}

static DWORD read32(BYTE *at) {
    DWORD value;
    memcpy(&value, at, 4);
    return value;
}

// Overwrites the function's first five bytes with a jump to the replacement.
static BOOL redirect(BYTE *from, void *to) {
    DWORD old;
    if (!VirtualProtect(from, 5, PAGE_EXECUTE_READWRITE, &old)) return FALSE;
    from[0] = 0xE9;
    DWORD offset = (DWORD)((BYTE *)to - (from + 5));
    memcpy(from + 1, &offset, 4);
    VirtualProtect(from, 5, old, &old);
    FlushInstructionCache(GetCurrentProcess(), from, 5);
    return TRUE;
}

// ---------------------------------------------------------------------------
// The particle system's catch-up. Each update, a particle system works out
// how many fixed steps of its simulation are due (its clock's time × its
// steps a second, less the steps already run) and runs them all. After a slow
// frame (a view loading its video) many are due, and under Rosetta, where the
// games' x87 maths runs in software, a step can take nearly as long as the
// time it simulates: the backlog barely shrinks, and the game stalls at a
// frame every few seconds for up to a minute (the snow behind Waverly's
// common room windows). So no more than a quarter of a second's steps are run
// in one update once a system is running; the rest are dropped, as the clock
// has already moved on, so the simulation stays on time and the particles
// skip ahead.

#define PARTICLE_CATCH_UP_SECONDS 0.25

// From the update, after fld1/fdivl [ebx+0x60] (st0 = 1 / steps a second):
//     mov eax, [ebx+0x68]   ; the clock's step count now
//     sub eax, edi          ; less the count before: the steps due
//     test eax, eax
//     mov [ebp-0xc], eax    ; the loop's counter
//     fstp qword [ebp-0x3c] ; the step's length
//     jle <none due>
// The 13 bytes before the jle become a jump to hook_particle_steps, which
// does the same with the count capped and returns to the jle.
static const char particle_pattern[] =
    "8B 7B 68 51 51 8D 73 58 DD 1C 24 89 7D E8 E8 ?? ?? ?? ?? D9 E8 DC 73 60 "
    "8B 43 68 2B C7 85 C0 89 45 F4 DD 5D C4 0F 8E";
#define PARTICLE_PATCH_OFFSET 24
#define PARTICLE_PATCH_LENGTH 13

__attribute__((used)) void *particle_return;

// `before` is the step count before this update: 0 for a system's first,
// which the game gives seconds at once to warm it up (two seconds' snow
// already falling when a view appears). That one is run whole, as the game
// would; only catch-up after it is capped.
__attribute__((used)) int __cdecl particle_steps(int due, int before, const double *stepsPerSecond) {
    int most = (int)(*stepsPerSecond * PARTICLE_CATCH_UP_SECONDS);
    if (most < 1) most = 1;
#ifdef ROSETTA_FIXES_STATS
    if (due > particle_most) particle_most = due;
    if (due > most && before == 0) particle_warmups++;
    if (due > most && before != 0) particle_capped++;
#endif
    return before != 0 && due > most ? most : due;
}
__asm__(
    ".text\n"
    "_hook_particle_steps:\n"
    "    fstpl -0x3c(%ebp)\n"         // the step's length, as the game did
    "    movl 0x68(%ebx), %eax\n"
    "    subl %edi, %eax\n"
    "    leal 0x60(%ebx), %ecx\n"
    "    pushl %ecx\n"
    "    pushl %edi\n"
    "    pushl %eax\n"
    "    call _particle_steps\n"      // may clobber ecx and edx, which the game sets again before use
    "    addl $12, %esp\n"
    "    movl %eax, -0xc(%ebp)\n"
    "    testl %eax, %eax\n"          // the flags the jle reads
    "    jmp *_particle_return\n");
extern char hook_particle_steps[];

// Overwrites `length` bytes at `from` with a jump to `to` and int3s.
static BOOL redirect_span(BYTE *from, void *to, int length) {
    DWORD old;
    if (!VirtualProtect(from, length, PAGE_EXECUTE_READWRITE, &old)) return FALSE;
    from[0] = 0xE9;
    DWORD offset = (DWORD)((BYTE *)to - (from + 5));
    memcpy(from + 1, &offset, 4);
    memset(from + 5, 0xCC, length - 5);
    VirtualProtect(from, length, old, &old);
    FlushInstructionCache(GetCurrentProcess(), from, length);
    return TRUE;
}

static void install_particles(const char *name, BYTE *code, BYTE *codeEnd) {
    BYTE *found = NULL;
    int count = find(code, codeEnd, particle_pattern, &found);
    if (count != 1) {
        say("%s: the particle update found %d times, not once; its particles are left as they are", name, count);
        return;
    }
    BYTE *site = found + PARTICLE_PATCH_OFFSET;
    particle_return = site + PARTICLE_PATCH_LENGTH;
    if (!redirect_span(site, hook_particle_steps, PARTICLE_PATCH_LENGTH)) {
        say("%s: couldn't patch the particle update (error %lu)", name, GetLastError());
        return;
    }
    say("%s: particle catch-up capped at %.2f s (0x%p)", name, PARTICLE_CATCH_UP_SECONDS, site);
}

static void install_sound(const char *name, BYTE *code, BYTE *codeEnd) {
    for (int i = 0; i < ENTRY_COUNT; i++) {
        int count = find(code, codeEnd, entries[i].pattern, &entries[i].found);
        if (count != 1) {
            say("%s: %s found %d times, not once; its sound is left as it is", name, entries[i].name, count);
            return;
        }
    }

    // The stdio callbacks ov_open builds, each an address in the game's code.
    BYTE *open = entries[OV_OPEN].found;
    DWORD stdio[4] = {read32(open + 9), read32(open + 16), read32(open + 24), read32(open + 36)};
    for (int i = 0; i < 4; i++) {
        if (stdio[i] < (DWORD)code || stdio[i] >= (DWORD)codeEnd) {
            say("%s: ov_open's callback %d (0x%08lx) isn't in its code; its sound is left as it is", name, i,
                (unsigned long)stdio[i]);
            return;
        }
    }
    game_stdio.read_func = (size_t (*)(void *, size_t, size_t, void *))stdio[0];
    game_stdio.seek_func = (int (*)(void *, ogg_int64_t, int))stdio[1];
    game_stdio.close_func = (int (*)(void *))stdio[2];
    game_stdio.tell_func = (long (*)(void *))stdio[3];

    void *replacements[ENTRY_COUNT] = {
        [OV_OPEN] = (void *)fast_ov_open,
        [OV_CLEAR] = (void *)hook_ov_clear,
        [OV_RAW_SEEK] = (void *)fast_ov_raw_seek,
        [OV_READ] = (void *)hook_ov_read,
    };
    for (int i = 0; i < ENTRY_COUNT; i++) {
        if (!redirect(entries[i].found, replacements[i])) {
            // Those already redirected stay so: they are whole functions,
            // and the game's state is the same layout either way.
            say("%s: couldn't redirect %s (error %lu)", name, entries[i].name, GetLastError());
            return;
        }
    }
    say("%s: Ogg Vorbis decoding replaced (ov_open 0x%p, ov_clear 0x%p, ov_raw_seek 0x%p, ov_read 0x%p)",
        name, entries[OV_OPEN].found, entries[OV_CLEAR].found, entries[OV_RAW_SEEK].found,
        entries[OV_READ].found);
}

static const char *program_name;
static BYTE *program_code, *program_code_end;

static void install_all(void) {
    install_sound(program_name, program_code, program_code_end);
    install_particles(program_name, program_code, program_code_end);
}

// Steam's copies are wrapped in its DRM (SteamStub, a .bind section): their
// code is encrypted on disk and decrypted by the stub when the game starts,
// after every DLL it loads has been given DllMain. So for them the fixes
// wait for the game's own code to run, which the C runtime's startup does
// first by asking for the command line: GetCommandLineA in the game's
// imports is pointed here until a call comes from the game's code.
static LPSTR (WINAPI *real_GetCommandLineA)(void);
static LPSTR (WINAPI **deferred_slot)(void);

static void put_slot(LPSTR (WINAPI *value)(void)) {
    DWORD old;
    if (VirtualProtect(deferred_slot, sizeof *deferred_slot, PAGE_READWRITE, &old)) {
        *deferred_slot = value;
        VirtualProtect(deferred_slot, sizeof *deferred_slot, old, &old);
    }
}

static LPSTR WINAPI deferred_GetCommandLineA(void) {
    BYTE *caller = (BYTE *)__builtin_return_address(0);
    // The C runtime's startup runs on the main thread alone.
    if (deferred_slot && caller >= program_code && caller < program_code_end) {
        put_slot(real_GetCommandLineA);
        deferred_slot = NULL;
        say("%s: its code is decrypted (Steam's DRM); patching it now", program_name);
        install_all();
    }
    return real_GetCommandLineA();
}

static BOOL defer_until_decrypted(BYTE *image, IMAGE_NT_HEADERS *headers) {
    real_GetCommandLineA = (LPSTR (WINAPI *)(void))GetProcAddress(GetModuleHandleA("kernel32.dll"), "GetCommandLineA");
    IMAGE_DATA_DIRECTORY imports = headers->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_IMPORT];
    if (!real_GetCommandLineA || !imports.VirtualAddress) return FALSE;
    for (IMAGE_IMPORT_DESCRIPTOR *d = (IMAGE_IMPORT_DESCRIPTOR *)(image + imports.VirtualAddress); d->Name; d++) {
        if (_stricmp((const char *)(image + d->Name), "kernel32.dll") != 0) continue;
        for (IMAGE_THUNK_DATA *slot = (IMAGE_THUNK_DATA *)(image + d->FirstThunk); slot->u1.Function; slot++) {
            if (slot->u1.Function == (DWORD)real_GetCommandLineA) {
                deferred_slot = (LPSTR (WINAPI **)(void))&slot->u1.Function;
                put_slot(deferred_GetCommandLineA);
                return TRUE;
            }
        }
    }
    return FALSE;
}

static void install(void) {
    char variable[8];
    DWORD length = GetEnvironmentVariableA("SECOND_CHANCE_ROSETTA_FIXES", variable, sizeof variable);
    if (length > 0 && length < sizeof variable && strcmp(variable, "0") == 0) {
        say("left off (SECOND_CHANCE_ROSETTA_FIXES=0)");
        return;
    }

    static char program[MAX_PATH];
    GetModuleFileNameA(NULL, program, sizeof program);
    program_name = strrchr(program, '\\') ? strrchr(program, '\\') + 1 : program;

    BYTE *image = (BYTE *)GetModuleHandleA(NULL);
    IMAGE_NT_HEADERS *headers = (IMAGE_NT_HEADERS *)(image + ((IMAGE_DOS_HEADER *)image)->e_lfanew);
    IMAGE_SECTION_HEADER *section = IMAGE_FIRST_SECTION(headers);
    BOOL steamStub = FALSE;
    for (int i = 0; i < headers->FileHeader.NumberOfSections; i++, section++) {
        if (memcmp(section->Name, ".text", 6) == 0) {
            program_code = image + section->VirtualAddress;
            program_code_end = program_code + section->Misc.VirtualSize;
        } else if (memcmp(section->Name, ".bind", 6) == 0) {
            steamStub = TRUE;
        }
    }
    if (!program_code) {
        say("%s has no .text section; it is left as it is", program_name);
        return;
    }
    if (steamStub) {
        if (!defer_until_decrypted(image, headers))
            say("%s: its code is encrypted (Steam's DRM), and GetCommandLineA isn't in its imports to wait on; it is left as it is",
                program_name);
        return;
    }
    install_all();
}

// ---------------------------------------------------------------------------
// comdlg32: each export a stub that jumps to Wine's own function, looked up
// the first time it's called.

static HMODULE real_comdlg32;

void *__cdecl rosetta_fixes_resolve(const char *name, void **slot) {
    if (!real_comdlg32) {
        char path[MAX_PATH];
        UINT length = GetSystemDirectoryA(path, MAX_PATH - 16);
        strcpy(path + length, "\\comdlg32.dll");
        real_comdlg32 = LoadLibraryA(path);
        if (!real_comdlg32 || real_comdlg32 == GetModuleHandleA(NULL)) {
            say("couldn't load %s (error %lu)", path, GetLastError());
            ExitProcess(1);
        }
    }
    void *function = (void *)GetProcAddress(real_comdlg32, name);
    if (!function) {
        say("Wine's comdlg32 has no %s", name);
        ExitProcess(1);
    }
    *slot = function;
    return function;
}

// The slots and names are only used from the stubs' assembly.
#define USED __attribute__((used))
#define FORWARD(name)                                   \
    static USED void *slot_##name;                      \
    static USED const char name_##name[] = #name;       \
    __asm__(".text\n"                                   \
            ".globl _" #name "\n"                       \
            "_" #name ":\n"                             \
            "    movl _slot_" #name ", %eax\n"          \
            "    testl %eax, %eax\n"                    \
            "    jnz 1f\n"                              \
            "    pushl $_slot_" #name "\n"              \
            "    pushl $_name_" #name "\n"              \
            "    call _rosetta_fixes_resolve\n"            \
            "    addl $8, %esp\n"                       \
            "1:  jmp *%eax\n");

FORWARD(ChooseColorA)
FORWARD(ChooseColorW)
FORWARD(ChooseFontA)
FORWARD(ChooseFontW)
FORWARD(CommDlgExtendedError)
FORWARD(FindTextA)
FORWARD(FindTextW)
FORWARD(GetFileTitleA)
FORWARD(GetFileTitleW)
FORWARD(GetOpenFileNameA)
FORWARD(GetOpenFileNameW)
FORWARD(GetSaveFileNameA)
FORWARD(GetSaveFileNameW)
FORWARD(PageSetupDlgA)
FORWARD(PageSetupDlgW)
FORWARD(PrintDlgA)
FORWARD(PrintDlgW)
FORWARD(PrintDlgExA)
FORWARD(PrintDlgExW)
FORWARD(ReplaceTextA)
FORWARD(ReplaceTextW)

BOOL WINAPI DllMain(HINSTANCE instance, DWORD reason, LPVOID reserved) {
    (void)reserved;
    if (reason == DLL_PROCESS_ATTACH) {
        DisableThreadLibraryCalls(instance);
        install();
    }
    return TRUE;
}
