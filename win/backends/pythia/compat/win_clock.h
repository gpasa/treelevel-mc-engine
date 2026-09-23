// SPDX-License-Identifier: MIT
// Windows stand-in for the POSIX clock_gettime, force-included ahead of everything (/FIwin_clock.h) so that
// Pythia 8 builds with MSVC untouched: Basics.h asks the clock for the CPU time of the current thread, which
// Windows measures with GetThreadTimes instead.
//
// Copyright (c) 2026 Guglielmo Pasa.

#ifndef TREELEVEL_COMPAT_WIN_CLOCK_H
#define TREELEVEL_COMPAT_WIN_CLOCK_H

#if defined(_WIN32)

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#ifndef NOGDI
#define NOGDI
#endif
#include <windows.h>
#include <time.h>       // MSVC declares struct timespec since C11; only the clocks are missing.

#ifndef CLOCK_REALTIME
#define CLOCK_REALTIME           0
#define CLOCK_MONOTONIC          1
#define CLOCK_PROCESS_CPUTIME_ID 2
#define CLOCK_THREAD_CPUTIME_ID  3
#endif

namespace treelevel_compat {

/// A FILETIME pair (kernel and user time, in units of 100 ns) as a timespec.
inline void ticksToTimespec(unsigned long long ticks, struct timespec* ts) {
  ts->tv_sec = static_cast<time_t>(ticks / 10000000ULL);
  ts->tv_nsec = static_cast<long>((ticks % 10000000ULL) * 100ULL);
}

inline unsigned long long ticksOf(const FILETIME& a, const FILETIME& b) {
  ULARGE_INTEGER first, second;
  first.LowPart = a.dwLowDateTime;   first.HighPart = a.dwHighDateTime;
  second.LowPart = b.dwLowDateTime;  second.HighPart = b.dwHighDateTime;
  return first.QuadPart + second.QuadPart;
}

}  // namespace treelevel_compat

inline int clock_gettime(int clock, struct timespec* ts) {
  if (ts == nullptr) return -1;
  FILETIME creation, exit, kernel, user;
  switch (clock) {
    case CLOCK_THREAD_CPUTIME_ID:
      if (!GetThreadTimes(GetCurrentThread(), &creation, &exit, &kernel, &user)) return -1;
      treelevel_compat::ticksToTimespec(treelevel_compat::ticksOf(kernel, user), ts);
      return 0;

    case CLOCK_PROCESS_CPUTIME_ID:
      if (!GetProcessTimes(GetCurrentProcess(), &creation, &exit, &kernel, &user)) return -1;
      treelevel_compat::ticksToTimespec(treelevel_compat::ticksOf(kernel, user), ts);
      return 0;

    case CLOCK_MONOTONIC: {
      LARGE_INTEGER frequency, counter;
      if (!QueryPerformanceFrequency(&frequency) || !QueryPerformanceCounter(&counter)) return -1;
      ts->tv_sec = static_cast<time_t>(counter.QuadPart / frequency.QuadPart);
      ts->tv_nsec = static_cast<long>(((counter.QuadPart % frequency.QuadPart) * 1000000000LL) / frequency.QuadPart);
      return 0;
    }

    default: {
      // The wall clock, counted from the Unix epoch rather than from 1601 as Windows does.
      FILETIME now;
      GetSystemTimePreciseAsFileTime(&now);
      ULARGE_INTEGER value;
      value.LowPart = now.dwLowDateTime;
      value.HighPart = now.dwHighDateTime;
      const unsigned long long epoch = 116444736000000000ULL;   // 1601 → 1970, in units of 100 ns
      treelevel_compat::ticksToTimespec(value.QuadPart - epoch, ts);
      return 0;
    }
  }
}

#endif  // _WIN32
#endif  // TREELEVEL_COMPAT_WIN_CLOCK_H
