/*
 * AI 人物标签批量工具 — 单文件自解压启动器
 *
 * exe 结构:  [本程序] [payload: 多个文件条目] [16字节尾: "AITAGPK1" + u64 payload偏移(LE)]
 * 条目格式:  u32 路径长度 | UTF-8 路径('/'分隔) | u64 文件大小 | 文件内容
 *
 * 运行流程:  首次运行把 payload 解压到 %LOCALAPPDATA%\AI-Tag-Tool\
 *           (以 install.ver 记录 payload 大小, 一致则跳过解压)
 *           然后静默启动 PowerShell 运行 app.ps1 图形界面。
 *
 * 交叉编译:  python3 -m ziglang cc -target x86_64-windows-gnu -O2 -s \
 *              -Wl,--subsystem,windows -o launcher.exe launcher.c
 * 本地测试:  cc -DTEST_CLI launcher.c -o launcher_test && ./launcher_test <解压目录>
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

#define MAGIC "AITAGPK1"
#define MAGIC_LEN 8
#define TRAILER_LEN 16

#ifdef _WIN32
#include <windows.h>
#include <direct.h>
typedef wchar_t pchar;
#define PF(s) L##s
static FILE *p_open(const pchar *p, const pchar *m) { return _wfopen(p, m); }
static void p_mkdir(const pchar *p) { _wmkdir(p); }
#else
#include <sys/stat.h>
typedef char pchar;
#define PF(s) s
static FILE *p_open(const pchar *p, const pchar *m) { return fopen(p, m); }
static void p_mkdir(const pchar *p) { mkdir(p, 0755); }
#endif

static size_t p_len(const pchar *s) { size_t n = 0; while (s[n]) n++; return n; }
static void p_cat(pchar *dst, const pchar *src) {
    size_t n = p_len(dst), i = 0;
    while (src[i]) { dst[n + i] = src[i]; i++; }
    dst[n + i] = 0;
}

/* UTF-8 -> pchar (Windows 转宽字符; 其他平台原样拷贝) */
static void utf8_to_p(const char *in, pchar *out, int outcap) {
#ifdef _WIN32
    MultiByteToWideChar(CP_UTF8, 0, in, -1, out, outcap);
#else
    int i = 0;
    while (in[i] && i < outcap - 1) { out[i] = in[i]; i++; }
    out[i] = 0;
#endif
}

/* 逐级创建 base 下的相对目录 (rel 以 '/' 分隔, 最后一段是文件名不建目录) */
static void make_parent_dirs(const pchar *base, const char *rel) {
    char partial[1024];
    int i = 0, j = 0;
    while (rel[i]) {
        if (rel[i] == '/') {
            partial[j] = 0;
            pchar wpart[1024], full[2048];
            utf8_to_p(partial, wpart, 1024);
            full[0] = 0;
            p_cat(full, base);
            p_cat(full, PF("/"));
            p_cat(full, wpart);
            p_mkdir(full);
        }
        partial[j++] = rel[i++];
    }
}

static uint32_t rd_u32(const unsigned char *b) {
    return (uint32_t)b[0] | ((uint32_t)b[1] << 8) | ((uint32_t)b[2] << 16) | ((uint32_t)b[3] << 24);
}
static uint64_t rd_u64(const unsigned char *b) {
    uint64_t v = 0;
    for (int i = 7; i >= 0; i--) v = (v << 8) | b[i];
    return v;
}

/* 返回 0 成功 */
static int extract_payload(const pchar *self_path, const pchar *dest) {
    FILE *f = p_open(self_path, PF("rb"));
    if (!f) return 1;
    if (fseek(f, -TRAILER_LEN, SEEK_END) != 0) { fclose(f); return 2; }
    long trailer_pos = ftell(f);
    unsigned char trailer[TRAILER_LEN];
    if (fread(trailer, 1, TRAILER_LEN, f) != TRAILER_LEN) { fclose(f); return 3; }
    if (memcmp(trailer, MAGIC, MAGIC_LEN) != 0) { fclose(f); return 4; }
    uint64_t off = rd_u64(trailer + MAGIC_LEN);
    uint64_t payload_size = (uint64_t)trailer_pos - off;

    /* 版本标记: payload 大小一致则跳过解压 */
    pchar verfile[2048];
    verfile[0] = 0; p_cat(verfile, dest); p_cat(verfile, PF("/install.ver"));
    p_mkdir(dest);
    {
        FILE *vf = p_open(verfile, PF("rb"));
        if (vf) {
            char buf[64] = {0};
            fread(buf, 1, 63, vf);
            fclose(vf);
            unsigned long long have = strtoull(buf, NULL, 10);
            if (have == payload_size) { fclose(f); return 0; } /* 已解压 */
        }
    }

    if (fseek(f, (long)off, SEEK_SET) != 0) { fclose(f); return 5; }
    uint64_t pos = off;
    char *buf = malloc(1 << 20);
    if (!buf) { fclose(f); return 6; }

    while (pos < (uint64_t)trailer_pos) {
        unsigned char hdr[4];
        if (fread(hdr, 1, 4, f) != 4) break;
        uint32_t plen = rd_u32(hdr);
        if (plen == 0 || plen > 1000) { free(buf); fclose(f); return 7; }
        char rel[1024];
        if (fread(rel, 1, plen, f) != plen) { free(buf); fclose(f); return 8; }
        rel[plen] = 0;
        unsigned char szb[8];
        if (fread(szb, 1, 8, f) != 8) { free(buf); fclose(f); return 9; }
        uint64_t fsize = rd_u64(szb);
        pos += 4 + plen + 8 + fsize;

        make_parent_dirs(dest, rel);
        pchar wrel[1024], full[2048];
        utf8_to_p(rel, wrel, 1024);
        full[0] = 0; p_cat(full, dest); p_cat(full, PF("/")); p_cat(full, wrel);
        FILE *out = p_open(full, PF("wb"));
        uint64_t left = fsize;
        while (left > 0) {
            size_t chunk = left > (1 << 20) ? (1 << 20) : (size_t)left;
            size_t got = fread(buf, 1, chunk, f);
            if (got == 0) break;
            if (out) fwrite(buf, 1, got, out);
            left -= got;
        }
        if (out) fclose(out);
        if (left != 0) { free(buf); fclose(f); return 10; }
    }
    free(buf);
    fclose(f);

    /* 写版本标记 */
    FILE *vf = p_open(verfile, PF("wb"));
    if (vf) {
        char num[64];
        snprintf(num, 64, "%llu", (unsigned long long)payload_size);
        fwrite(num, 1, strlen(num), vf);
        fclose(vf);
    }
    return 0;
}

#ifdef TEST_CLI
/* ---------------- Linux/本地 测试入口 ---------------- */
int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: %s <destdir>\n", argv[0]); return 1; }
    int rc = extract_payload(argv[0], argv[1]);
    printf("extract rc=%d\n", rc);
    return rc;
}
#else
#ifdef _WIN32
/* ---------------- Windows GUI 入口 ---------------- */
static void dbg_log(const wchar_t *self, const char *msg) {
    /* 在 exe 同目录写 launcher.log 便于排障 */
    wchar_t logp[MAX_PATH * 2];
    size_t n = 0;
    while (self[n]) n++;
    size_t cut = n;
    while (cut > 0 && self[cut - 1] != L'\\') cut--;
    for (size_t i = 0; i < cut; i++) logp[i] = self[i];
    logp[cut] = 0;
    p_cat(logp, L"launcher.log");
    FILE *lf = _wfopen(logp, L"ab");
    if (lf) { fprintf(lf, "%s\r\n", msg); fclose(lf); }
}

int WINAPI WinMain(HINSTANCE hI, HINSTANCE hP, LPSTR cmd, int show) {
    (void)hI; (void)hP; (void)cmd; (void)show;
    wchar_t self[MAX_PATH];
    GetModuleFileNameW(NULL, self, MAX_PATH);

    wchar_t dest[MAX_PATH * 2];
    wchar_t *local = _wgetenv(L"LOCALAPPDATA");
    if (!local) {
        MessageBoxW(NULL, L"找不到 LOCALAPPDATA 环境变量", L"错误", MB_ICONERROR);
        return 1;
    }
    dest[0] = 0;
    p_cat(dest, local);
    p_cat(dest, L"\\AI-Tag-Tool");

    int rc = extract_payload(self, dest);
    if (rc != 0) {
        wchar_t msg[128];
        _snwprintf(msg, 128, L"程序资源解压失败 (错误码 %d)。\n请确认磁盘空间充足后重试。", rc);
        MessageBoxW(NULL, msg, L"AI 人物标签批量工具", MB_ICONERROR);
        return rc;
    }

    /* 启动 PowerShell 图形界面 */
    wchar_t psexe[MAX_PATH * 2];
    wchar_t *sysroot = _wgetenv(L"SystemRoot");
    psexe[0] = 0;
    if (sysroot) { p_cat(psexe, sysroot); p_cat(psexe, L"\\System32\\WindowsPowerShell\\v1.0\\powershell.exe"); }
    else { p_cat(psexe, L"powershell.exe"); }

    wchar_t cmdline[MAX_PATH * 4];
    cmdline[0] = 0;
    p_cat(cmdline, L"\"");
    p_cat(cmdline, psexe);
    p_cat(cmdline, L"\" -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File \"");
    p_cat(cmdline, dest);
    p_cat(cmdline, L"\\app.ps1\"");

    /* 注意: 不能用 STARTF_USESHOWWINDOW+SW_HIDE —— 它会把 WinForms 主窗口
       的首次显示也一并隐藏(界面在跑但看不见)。CREATE_NO_WINDOW 已足够隐藏控制台。 */
    STARTUPINFOW si;
    PROCESS_INFORMATION pi;
    memset(&si, 0, sizeof(si));
    si.cb = sizeof(si);
    if (!CreateProcessW(NULL, cmdline, NULL, NULL, FALSE,
                        CREATE_NO_WINDOW, NULL, NULL, &si, &pi)) {
        MessageBoxW(NULL, L"无法启动 Windows PowerShell。", L"AI 人物标签批量工具", MB_ICONERROR);
        return 2;
    }
    CloseHandle(pi.hProcess);
    CloseHandle(pi.hThread);
    return 0;
}
#endif
#endif
