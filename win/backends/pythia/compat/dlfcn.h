// SPDX-License-Identifier: MIT
// Windows stand-in for the POSIX <dlfcn.h>, put on the include path ahead of the compiler's headers so that
// Pythia 8 builds with MSVC without a single change to its sources: PythiaStdlib.h includes <dlfcn.h>
// unconditionally, and Plugins.cc loads generator plugins with dlopen/dlsym/dlclose/dlerror.
//
// Only what Pythia uses is provided. The flags are accepted and ignored: LoadLibrary has no lazy binding and
// its symbols are never global, which is what a plugin needs anyway.
//
// Copyright (c) 2026 Guglielmo Pasa.

#ifndef TREELEVEL_COMPAT_DLFCN_H
#define TREELEVEL_COMPAT_DLFCN_H

#if defined(_WIN32)

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX            // keeps the min/max macros away from std::min and std::max
#endif
#ifndef NOGDI
#define NOGDI               // keeps the ERROR macro away from Pythia's logger
#endif
#include <windows.h>
#include <string>

#define RTLD_LAZY   0x0001
#define RTLD_NOW    0x0002
#define RTLD_GLOBAL 0x0100
#define RTLD_LOCAL  0x0000

namespace treelevel_compat {

/// The message dlerror() will hand out once; per thread, as dlerror() is.
inline std::string& dlLastError() {
  static thread_local std::string message;
  return message;
}

inline void dlSetError(const char* what, const char* name) {
  char code[32];
  snprintf(code, sizeof code, " (error %lu)", static_cast<unsigned long>(GetLastError()));
  dlLastError() = std::string(what) + " " + name + code;
}

}  // namespace treelevel_compat

inline void* dlopen(const char* name, int /*flags*/) {
  if (name == nullptr) return reinterpret_cast<void*>(GetModuleHandleA(nullptr));
  HMODULE handle = LoadLibraryA(name);
  if (handle == nullptr) treelevel_compat::dlSetError("cannot load", name);
  return reinterpret_cast<void*>(handle);
}

inline void* dlsym(void* handle, const char* symbol) {
  FARPROC address = GetProcAddress(static_cast<HMODULE>(handle), symbol);
  if (address == nullptr) treelevel_compat::dlSetError("no symbol", symbol);
  return reinterpret_cast<void*>(address);
}

inline int dlclose(void* handle) {
  if (FreeLibrary(static_cast<HMODULE>(handle))) return 0;
  treelevel_compat::dlSetError("cannot unload", "library");
  return -1;
}

/// The last error, or nullptr when there was none; reading it clears it, as POSIX says.
inline const char* dlerror() {
  std::string& message = treelevel_compat::dlLastError();
  if (message.empty()) return nullptr;
  static thread_local std::string handed;
  handed = message;
  message.clear();
  return handed.c_str();
}

#endif  // _WIN32
#endif  // TREELEVEL_COMPAT_DLFCN_H
