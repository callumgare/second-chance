// display_mode.exe <width> <height> [<depth>]: sets the display mode (and its
// colour depth, when given) for the rest of the Wine session (no
// CDS_FULLSCREEN, so nothing puts it back when this exits),
// prints the mode the session then has, and exits 0 if the change was made.
#include <windows.h>

static unsigned parse(const WCHAR **p) {
    unsigned value = 0;
    while (**p == L' ' || **p == L'\t') (*p)++;
    while (**p >= L'0' && **p <= L'9') value = value * 10 + (unsigned)(*(*p)++ - L'0');
    return value;
}

static void say(const char *text) {
    DWORD written, length = 0;
    while (text[length]) length++;
    WriteFile(GetStdHandle(STD_OUTPUT_HANDLE), text, length, &written, NULL);
}

static char *number(char *at, unsigned value) {
    char digits[10];
    int count = 0;
    do { digits[count++] = (char)('0' + value % 10); value /= 10; } while (value);
    while (count) *at++ = digits[--count];
    return at;
}

void start(void) {
    const WCHAR *line = GetCommandLineW();
    // Skip the program's own name, quoted or not.
    if (*line == L'"') { line++; while (*line && *line != L'"') line++; if (*line) line++; }
    else { while (*line && *line != L' ' && *line != L'\t') line++; }
    unsigned width = parse(&line), height = parse(&line), depth = parse(&line);
    if (!width || !height) { say("usage: display_mode <width> <height> [<depth>]\n"); ExitProcess(2); }

    DEVMODEW mode;
    for (unsigned i = 0; i < sizeof(mode); i++) ((char *)&mode)[i] = 0;
    mode.dmSize = sizeof(mode);
    mode.dmFields = DM_PELSWIDTH | DM_PELSHEIGHT;
    mode.dmPelsWidth = width;
    mode.dmPelsHeight = height;
    // A depth keeps the mode's own refresh rate out of it: Wine's emulated
    // modes are all 60 Hz, and one filled in from a 120 Hz display matches none.
    if (depth) { mode.dmFields |= DM_BITSPERPEL; mode.dmBitsPerPel = depth; }
    LONG result = ChangeDisplaySettingsExW(NULL, &mode, NULL, 0, NULL);

    char text[96], *at = text;
    const char *label = "result ";
    while (*label) *at++ = *label++;
    if (result < 0) { *at++ = '-'; at = number(at, (unsigned)-result); } else at = number(at, (unsigned)result);
    const char *now = ", now ";
    while (*now) *at++ = *now++;
    at = number(at, (unsigned)GetSystemMetrics(SM_CXSCREEN));
    *at++ = 'x';
    at = number(at, (unsigned)GetSystemMetrics(SM_CYSCREEN));
    HDC screen = GetDC(NULL);
    *at++ = 'x';
    at = number(at, (unsigned)GetDeviceCaps(screen, BITSPIXEL));
    ReleaseDC(NULL, screen);
    *at++ = '\n';
    *at = 0;
    say(text);
    ExitProcess(result == DISP_CHANGE_SUCCESSFUL ? 0 : 1);
}
