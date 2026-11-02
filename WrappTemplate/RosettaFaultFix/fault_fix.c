// fault_fix.c — runs inside Wine's 32-bit ntdll, before any exception handler,
// for faults Rosetta 2 raises that Windows wouldn't. RosettaFaultFix.swift
// (Packages/SecondChanceKit) embeds the machine code this compiles to;
// regenerate.sh rebuilds it. docs/big-fish.md#armadillo-under-rosetta has why.
//
// 1. An fs: access with the 0x67 address-size prefix (16-bit addressing in
//    32-bit code). Rosetta raises an access violation for it instead of
//    running it. Armadillo, the DRM on Big Fish's games, unlinks its exception
//    handlers with one ("pop dword fs:[0000]", 64 67 8F 06 00 00); left
//    linked, the next fault calls garbage. Performed here instead.
// 2. int 68h / int 41h, the Windows 9x probes for the SoftICE debugger. Wine
//    on macOS runs 32-bit code in an LDT segment (cs 0x107), so code that tells
//    9x from NT by cs's high byte takes the 9x path and probes, and the int
//    faults. Without SoftICE they do nothing, so they're skipped.
//
// Called as bf_fault_fix(record, context) from KiUserExceptionDispatcher.
// Returns 1 when it handled the fault (the context is updated and is resumed
// with NtContinue), 0 to dispatch the exception as usual. It is copied into
// ntdll as raw bytes, so it must have no relocations: no globals, no calls,
// no jump tables (regenerate.sh checks).
typedef unsigned int u32;
typedef unsigned short u16;
typedef unsigned char u8;

// i386 CONTEXT offsets.
#define CTX_EDI 0x9C
#define CTX_ESI 0xA0
#define CTX_EBX 0xA4
#define CTX_EDX 0xA8
#define CTX_ECX 0xAC
#define CTX_EAX 0xB0
#define CTX_EBP 0xB4
#define CTX_EIP 0xB8
#define CTX_ESP 0xC4

// EXCEPTION_RECORD: code at 0, ExceptionInformation[] from 0x14 (u32 index 5).
#define STATUS_ACCESS_VIOLATION 0xC0000005

static inline u32 *reg(u8 *ctx, int r) {
    u32 off = r == 0 ? CTX_EAX : r == 1 ? CTX_ECX : r == 2 ? CTX_EDX : r == 3 ? CTX_EBX
            : r == 4 ? CTX_ESP : r == 5 ? CTX_EBP : r == 6 ? CTX_ESI : CTX_EDI;
    return (u32 *)(ctx + off);
}

int __attribute__((stdcall)) bf_fault_fix(const u32 *record, u8 *ctx) {
    if (record[0] != STATUS_ACCESS_VIOLATION) return 0;
    const u8 *p = (const u8 *)*(u32 *)(ctx + CTX_EIP);

    // int 68h / int 41h: Wine reports the fault as a read of 0xFFFFFFFF.
    if (p[0] == 0xCD && (p[1] == 0x68 || p[1] == 0x41) && record[5] == 0 && record[6] == 0xFFFFFFFF) {
        *(u32 *)(ctx + CTX_EIP) += 2;
        return 1;
    }

    if (p[0] != 0x64 || p[1] != 0x67) return 0;
    u8 *teb;
    __asm__("movl %%fs:0x18, %0" : "=r"(teb));
    u8 op = p[2], modrm = p[3];
    u32 *esp = (u32 *)(ctx + CTX_ESP);
    u32 len;
    if (op == 0xA1 || op == 0xA3) {                      // mov eax, fs:[moffs16] / mov fs:[moffs16], eax
        u32 *m = (u32 *)(teb + *(const u16 *)(p + 3));
        if (op == 0xA1) *reg(ctx, 0) = *m; else *m = *reg(ctx, 0);
        len = 5;
    } else {
        if ((modrm & 0xC7) != 0x06) return 0;            // only [disp16]
        u32 *m = (u32 *)(teb + *(const u16 *)(p + 4));
        int r = (modrm >> 3) & 7;
        if (op == 0x8F && r == 0) { *m = *(u32 *)*esp; *esp += 4; }        // pop
        else if (op == 0xFF && r == 6) { *esp -= 4; *(u32 *)*esp = *m; }   // push
        else if (op == 0x89) *m = *reg(ctx, r);                             // mov m, r
        else if (op == 0x8B) *reg(ctx, r) = *m;                             // mov r, m
        else return 0;
        len = 6;
    }
    *(u32 *)(ctx + CTX_EIP) += len;
    return 1;
}
