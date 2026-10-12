// QIP filesystem port. Skia has no files or file descriptors in this module.
#include "src/core/SkOSFile.h"
FILE* sk_fopen(const char[], SkFILE_Flags) { return nullptr; }
void sk_fclose(FILE*) {}
size_t sk_fgetsize(FILE*) { return 0; }
size_t sk_fwrite(const void*, size_t, FILE*) { return 0; }
void sk_fflush(FILE*) {}
void sk_fsync(FILE*) {}
size_t sk_ftell(FILE*) { return 0; }
void* sk_fmmap(FILE*, size_t*) { return nullptr; }
void* sk_fdmmap(int, size_t*) { return nullptr; }
void sk_fmunmap(const void*, size_t) { __builtin_trap(); }
bool sk_fidentical(FILE*, FILE*) { return false; }
int sk_fileno(FILE*) { return -1; }
bool sk_exists(const char*, SkFILE_Flags) { return false; }
bool sk_isdir(const char*) { return false; }
size_t sk_qread(FILE*, void*, size_t, size_t) { return SIZE_MAX; }
bool sk_mkdir(const char*) { return false; }
SkOSFile::Iter::Iter() {}
SkOSFile::Iter::Iter(const char[], const char[]) {}
SkOSFile::Iter::~Iter() {}
void SkOSFile::Iter::reset(const char[], const char[]) {}
bool SkOSFile::Iter::next(SkString*, bool) { return false; }
