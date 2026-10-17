/* SynthTag single-file Windows launcher. Link with -lbcrypt.
 * Format: launcher | repeated (u32 UTF-8 path length, path, u64 size, data)
 *         | "AITAGPK1" | u64 payload offset.
 * Cache identity includes version and SHA-256 of every payload byte.
 */
#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0601
#endif
#include <windows.h>
#include <bcrypt.h>
#include <direct.h>
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>
#include <errno.h>

#define APP_VERSION_TEXT "1.3.0"
#define WIDE_TEXT_INNER(text) L##text
#define WIDE_TEXT(text) WIDE_TEXT_INNER(text)
#define APP_VERSION WIDE_TEXT(APP_VERSION_TEXT)
#define MAGIC "AITAGPK1"
#define PATH_CAP 32768
#define CHUNK (1 << 20)

typedef struct { uint64_t offset, end; char hash[65]; } Payload;
static wchar_t log_dir[PATH_CAP];

static int join(wchar_t *out, const wchar_t *base, const wchar_t *rel) {
    return swprintf(out, PATH_CAP, L"%ls\\%ls", base, rel) > 0;
}

static int mkdir_tree(const wchar_t *path) {
    wchar_t tmp[PATH_CAP];
    if (wcslen(path) >= PATH_CAP) return 0;
    wcscpy(tmp, path);
    for (size_t i = 3; tmp[i]; i++) {
        if (tmp[i] == L'\\' || tmp[i] == L'/') {
            wchar_t c = tmp[i]; tmp[i] = 0;
            if (_wmkdir(tmp) && errno != EEXIST) return 0;
            tmp[i] = c;
        }
    }
    if (_wmkdir(tmp) && errno != EEXIST) return 0;
    DWORD attr = GetFileAttributesW(tmp);
    return attr != INVALID_FILE_ATTRIBUTES && (attr & FILE_ATTRIBUTE_DIRECTORY);
}

static void log_message(const char *level, const char *msg, unsigned long code) {
    if (!log_dir[0]) return;
    SYSTEMTIME now; GetLocalTime(&now);
    wchar_t name[64], path[PATH_CAP];
    swprintf(name, 64, L"launcher-%04d-%02d-%02d.log", now.wYear, now.wMonth, now.wDay);
    if (!join(path, log_dir, name)) return;
    FILE *f = _wfopen(path, L"ab");
    if (!f) return;
    fprintf(f, "%04d-%02d-%02d %02d:%02d:%02d [%s] version=" APP_VERSION_TEXT " %s code=%lu\r\n",
            now.wYear, now.wMonth, now.wDay, now.wHour, now.wMinute, now.wSecond,
            level, msg, code);
    fclose(f);
}

static void init_logs(const wchar_t *root) {
    if (!join(log_dir, root, L"Logs") || !mkdir_tree(log_dir)) { log_dir[0] = 0; return; }
    wchar_t pattern[PATH_CAP], path[PATH_CAP];
    join(pattern, log_dir, L"launcher-*.log");
    WIN32_FIND_DATAW entry;
    HANDLE find = FindFirstFileW(pattern, &entry);
    if (find == INVALID_HANDLE_VALUE) return;
    SYSTEMTIME today; GetLocalTime(&today);
    today.wHour = today.wMinute = today.wSecond = today.wMilliseconds = 0;
    FILETIME ft; SystemTimeToFileTime(&today, &ft);
    ULARGE_INTEGER current; current.LowPart = ft.dwLowDateTime; current.HighPart = ft.dwHighDateTime;
    const uint64_t day = 864000000000ULL;
    do {
        unsigned year, month, date; wchar_t tail;
        if (entry.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) continue;
        if (swscanf(entry.cFileName, L"launcher-%4u-%2u-%2u.log%c", &year, &month, &date, &tail) != 3) continue;
        SYSTEMTIME stamped = {0}; stamped.wYear = (WORD)year; stamped.wMonth = (WORD)month; stamped.wDay = (WORD)date;
        if (!SystemTimeToFileTime(&stamped, &ft)) continue;
        ULARGE_INTEGER created; created.LowPart = ft.dwLowDateTime; created.HighPart = ft.dwHighDateTime;
        if (current.QuadPart >= created.QuadPart && current.QuadPart - created.QuadPart >= 30 * day && join(path, log_dir, entry.cFileName))
            DeleteFileW(path);
    } while (FindNextFileW(find, &entry));
    FindClose(find);
}

static uint32_t rd32(const unsigned char *b) {
    return (uint32_t)b[0] | ((uint32_t)b[1] << 8) | ((uint32_t)b[2] << 16) | ((uint32_t)b[3] << 24);
}
static uint64_t rd64(const unsigned char *b) {
    uint64_t v = 0; for (int i = 7; i >= 0; i--) v = (v << 8) | b[i]; return v;
}

/* Validate the trailer and hash the actual payload, never just its length. */
static int inspect_payload(const wchar_t *self, Payload *p) {
    FILE *f = _wfopen(self, L"rb");
    unsigned char trailer[16], digest[32], buf[65536];
    BCRYPT_ALG_HANDLE alg = NULL; BCRYPT_HASH_HANDLE hash = NULL;
    int rc = 1;
    if (!f) return rc;
    if (_fseeki64(f, 0, SEEK_END)) goto done;
    __int64 size = _ftelli64(f);
    if (size < 16 || _fseeki64(f, size - 16, SEEK_SET) || fread(trailer, 1, 16, f) != 16) goto done;
    if (memcmp(trailer, MAGIC, 8)) { rc = 2; goto done; }
    p->offset = rd64(trailer + 8); p->end = (uint64_t)size - 16;
    if (p->offset >= p->end || _fseeki64(f, (__int64)p->offset, SEEK_SET)) { rc = 3; goto done; }
    if (BCryptOpenAlgorithmProvider(&alg, BCRYPT_SHA256_ALGORITHM, NULL, 0) < 0 ||
        BCryptCreateHash(alg, &hash, NULL, 0, NULL, 0, 0) < 0) { rc = 4; goto done; }
    uint64_t left = p->end - p->offset;
    while (left) {
        size_t n = left > sizeof(buf) ? sizeof(buf) : (size_t)left;
        if (fread(buf, 1, n, f) != n || BCryptHashData(hash, buf, (ULONG)n, 0) < 0) { rc = 5; goto done; }
        left -= n;
    }
    if (BCryptFinishHash(hash, digest, sizeof(digest), 0) < 0) { rc = 6; goto done; }
    for (int i = 0; i < 32; i++) sprintf(p->hash + i * 2, "%02x", digest[i]);
    rc = 0;
done:
    if (hash) BCryptDestroyHash(hash);
    if (alg) BCryptCloseAlgorithmProvider(alg, 0);
    fclose(f); return rc;
}

static int valid_relative(const char *rel, uint32_t length) {
    if (!length || rel[0] == '/' || rel[0] == '\\') return 0;
    const char *part = rel;
    for (uint32_t i = 0; i <= length; i++) {
        unsigned char c = (unsigned char)rel[i];
        if (i < length && (c < 32 || strchr(":\\<>\"|?*", c))) return 0;
        if (c == '/' || i == length) {
            size_t n = (size_t)(rel + i - part);
            /* Win32 normalizes trailing dots/spaces; reject them before joining. */
            if (!n || part[n - 1] == '.' || part[n - 1] == ' ') return 0;
            size_t stem = 0; while (stem < n && part[stem] != '.') stem++;
            if ((stem == 3 && (!_strnicmp(part, "CON", 3) || !_strnicmp(part, "NUL", 3) ||
                              !_strnicmp(part, "AUX", 3) || !_strnicmp(part, "PRN", 3))) ||
                (stem == 4 && (!_strnicmp(part, "COM", 3) || !_strnicmp(part, "LPT", 3)) &&
                 part[3] >= '1' && part[3] <= '9')) return 0;
            part = rel + i + 1;
        }
    }
    return 1;
}

/* A marker only identifies the expected payload. Compare every cached byte to
 * that payload before reuse, including the complete nested Perl dependency tree.
 * Byte equality is stronger than a per-file hash and also detects truncation. */
static int cache_matches_payload(const wchar_t *self, const wchar_t *dest, const Payload *p) {
    FILE *source = _wfopen(self, L"rb"), *cached = NULL;
    unsigned char *buffers = malloc(131072);
    wchar_t relative[1024], full[PATH_CAP];
    uint64_t pos = p->offset;
    int matches = 0;
    if (!source || !buffers || _fseeki64(source, (__int64)pos, SEEK_SET)) goto done;
    while (pos < p->end) {
        unsigned char hdr[4], sz[8]; char rel[1024];
        if (p->end - pos < 4 || fread(hdr, 1, 4, source) != 4) goto done;
        uint32_t length = rd32(hdr); pos += 4;
        if (!length || length >= sizeof(rel) || p->end - pos < length + 8ULL) goto done;
        if (fread(rel, 1, length, source) != length || fread(sz, 1, 8, source) != 8) goto done;
        rel[length] = 0; pos += length + 8;
        uint64_t size = rd64(sz);
        if (size > p->end - pos || !valid_relative(rel, length) ||
            !MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, rel, -1, relative, 1024) ||
            !join(full, dest, relative)) goto done;
        cached = _wfopen(full, L"rb");
        if (!cached || _fseeki64(cached, 0, SEEK_END) || _ftelli64(cached) != (__int64)size ||
            _fseeki64(cached, 0, SEEK_SET)) goto done;
        uint64_t left = size;
        while (left) {
            size_t count = left > 65536 ? 65536 : (size_t)left;
            if (fread(buffers, 1, count, source) != count ||
                fread(buffers + 65536, 1, count, cached) != count ||
                memcmp(buffers, buffers + 65536, count)) goto done;
            left -= count;
        }
        fclose(cached); cached = NULL;
        pos += size;
    }
    matches = 1;
done:
    if (cached) fclose(cached);
    if (source) fclose(source);
    free(buffers);
    return matches;
}

/* Nonzero on ANY output, directory, read, flush, close or marker failure.
 * install.ver is written only after the complete payload succeeds. */
static int extract_payload(const wchar_t *self, const wchar_t *dest, const Payload *p) {
    wchar_t marker[PATH_CAP], full[PATH_CAP], relative[1024];
    FILE *f = NULL, *out = NULL; char *buf = NULL;
    int rc = 10; uint64_t pos = p->offset;
    if (!join(marker, dest, L"install.ver") || !mkdir_tree(dest)) return rc;
    FILE *vf = _wfopen(marker, L"rb");
    if (vf) {
        char have[66] = {0}; size_t n = fread(have, 1, 65, vf); fclose(vf);
        if (n == 64 && !strcmp(have, p->hash) && cache_matches_payload(self, dest, p)) return 0;
    }
    /* Invalidate first even when an existing marker could not be opened. Never
     * modify cached files while an old success marker remains inaccessible. */
    DWORD marker_attributes = GetFileAttributesW(marker);
    if (marker_attributes != INVALID_FILE_ATTRIBUTES) {
        if ((marker_attributes & FILE_ATTRIBUTE_DIRECTORY) || !DeleteFileW(marker)) return 11;
    } else if (GetLastError() != ERROR_FILE_NOT_FOUND && GetLastError() != ERROR_PATH_NOT_FOUND) return 11;
    f = _wfopen(self, L"rb");
    if (!f || _fseeki64(f, (__int64)p->offset, SEEK_SET)) { rc = 12; goto done; }
    buf = malloc(CHUNK); if (!buf) { rc = 13; goto done; }
    while (pos < p->end) {
        unsigned char hdr[4], sz[8]; char rel[1024];
        if (p->end - pos < 4 || fread(hdr, 1, 4, f) != 4) { rc = 14; goto done; }
        uint32_t len = rd32(hdr); pos += 4;
        if (len == 0 || len >= sizeof(rel) || p->end - pos < len + 8ULL) { rc = 15; goto done; }
        if (fread(rel, 1, len, f) != len || fread(sz, 1, 8, f) != 8) { rc = 16; goto done; }
        rel[len] = 0; pos += len + 8;
        uint64_t size = rd64(sz);
        if (!valid_relative(rel, len) || size > p->end - pos) { rc = 17; goto done; }
        if (!MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, rel, -1, relative, 1024) || !join(full, dest, relative)) { rc = 18; goto done; }
        wchar_t *slash = wcsrchr(full, L'/');
        if (slash) { *slash = 0; if (!mkdir_tree(full)) { rc = 19; goto done; } *slash = L'/'; }
        out = _wfopen(full, L"wb"); if (!out) { rc = 20; goto done; }
        uint64_t left = size;
        while (left) {
            size_t n = left > CHUNK ? CHUNK : (size_t)left;
            if (fread(buf, 1, n, f) != n) { rc = 21; goto done; }
            if (fwrite(buf, 1, n, out) != n) { rc = 22; goto done; }
            left -= n;
        }
        int flushed = fflush(out); int closed = fclose(out); out = NULL;
        if (flushed || closed) { rc = 23; goto done; }
        pos += size;
    }
    vf = _wfopen(marker, L"wb"); if (!vf) { rc = 24; goto done; }
    size_t wrote = fwrite(p->hash, 1, 64, vf); int flushed = fflush(vf); int closed = fclose(vf);
    if (wrote != 64 || flushed || closed) { DeleteFileW(marker); rc = 25; goto done; }
    rc = 0;
done:
    if (out) fclose(out);
    if (f) fclose(f);
    free(buf);
    return rc;
}

#ifdef TEST_CLI
/* Test helper: launcher_test.exe <payload.exe> <dest>. It never launches UI. */
int main(int argc, char **argv) {
    wchar_t self[PATH_CAP], dest[PATH_CAP]; Payload p;
    if (argc != 3 || !MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, argv[1], -1, self, PATH_CAP) ||
        !MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, argv[2], -1, dest, PATH_CAP)) return 99;
    int rc = inspect_payload(self, &p);
    if (!rc) rc = extract_payload(self, dest, &p);
    printf("extract rc=%d\n", rc); return rc;
}
#else
int WINAPI WinMain(HINSTANCE instance, HINSTANCE previous, LPSTR args, int show) {
    (void)instance; (void)previous; (void)args; (void)show;
    wchar_t self[PATH_CAP], root[PATH_CAP], cache[PATH_CAP], dest[PATH_CAP], name[128];
    Payload p;
    wchar_t *local = _wgetenv(L"LOCALAPPDATA");
    if (!local || !join(root, local, L"SynthTag") || !mkdir_tree(root)) {
        MessageBoxW(NULL, L"无法创建本地应用目录，请检查 LOCALAPPDATA 与磁盘权限。", L"SynthTag（打AI标签）", MB_ICONERROR); return 1;
    }
    init_logs(root); log_message("INFO", "Launcher started", 0);
    DWORD length = GetModuleFileNameW(NULL, self, PATH_CAP);
    int rc = (!length || length >= PATH_CAP) ? 7 : inspect_payload(self, &p);
    if (rc) { log_message("ERROR", "Payload validation failed", rc); goto error; }
    wchar_t digest[65]; MultiByteToWideChar(CP_UTF8, 0, p.hash, -1, digest, 65);
    swprintf(name, 128, L"%ls-%ls", APP_VERSION, digest);
    if (!join(cache, root, L"Cache") || !join(dest, cache, name) || !mkdir_tree(dest)) { rc = 10; goto error; }
    swprintf(name, 128, L"Local\\SynthTag-%ls", digest);
    HANDLE mutex = CreateMutexW(NULL, FALSE, name);
    DWORD waited = mutex ? WaitForSingleObject(mutex, 60000) : WAIT_FAILED;
    if (waited != WAIT_OBJECT_0 && waited != WAIT_ABANDONED) {
        rc = 26; if (mutex) CloseHandle(mutex); goto error;
    }
    rc = extract_payload(self, dest, &p);
    ReleaseMutex(mutex); CloseHandle(mutex);
    if (rc) goto error;
    log_message("INFO", "Payload cache ready", 0);
    wchar_t psexe[PATH_CAP], script[PATH_CAP], command[PATH_CAP * 2];
    DWORD syslen = GetSystemDirectoryW(psexe, PATH_CAP);
    if (!syslen || syslen >= PATH_CAP || wcscat_s(psexe, PATH_CAP, L"\\WindowsPowerShell\\v1.0\\powershell.exe") || !join(script, dest, L"app.ps1")) { rc = 27; goto error; }
    if (swprintf(command, PATH_CAP * 2, L"\"%ls\" -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File \"%ls\"", psexe, script) < 0) { rc = 28; goto error; }
    STARTUPINFOW si = {0}; PROCESS_INFORMATION pi; si.cb = sizeof(si);
    if (!CreateProcessW(psexe, command, NULL, NULL, FALSE, CREATE_NO_WINDOW, NULL, dest, &si, &pi)) {
        log_message("ERROR", "PowerShell creation failed", GetLastError()); rc = 29; goto error;
    }
    CloseHandle(pi.hThread); CloseHandle(pi.hProcess);
    log_message("INFO", "PowerShell started", 0); return 0;
error:
    log_message("ERROR", "Launcher failed", (unsigned long)rc);
    wchar_t message[256];
    swprintf(message, 256, L"程序启动失败（错误码 %d）。请检查磁盘空间和本地目录权限。\n日志位于 %%LOCALAPPDATA%%\\SynthTag\\Logs。", rc);
    MessageBoxW(NULL, message, L"SynthTag（打AI标签）", MB_ICONERROR); return rc;
}
#endif
