/* A monotonic clock, which OCaml's Unix does not expose: it gives the civil
   clock (`gettimeofday`), CPU time (`times`), and the interval timers.
   Measuring how long work took needs a reading that no NTP correction and
   no operator can move.

   Time while the machine is suspended counts. A script measures elapsed
   real time, and a laptop that slept for seven hours did take seven hours.
   That is CLOCK_BOOTTIME on Linux and CLOCK_MONOTONIC on macOS -- the names
   are inverted between the two, and this is the one place that knows it.
   The clocks that stop while suspended are CLOCK_MONOTONIC on Linux and
   CLOCK_UPTIME_RAW on macOS.

   The answer is milliseconds since an arbitrary point in this run, which is
   what wand's durations are counted in. Only differences mean anything. */

#include <caml/mlvalues.h>
#include <time.h>

#if defined(__linux__)
#define WAND_CLOCK CLOCK_BOOTTIME
#else
#define WAND_CLOCK CLOCK_MONOTONIC
#endif

CAMLprim value wand_elapsed_ms(value unit)
{
  struct timespec ts;
  (void)unit;
  clock_gettime(WAND_CLOCK, &ts);
  return Val_long((intnat)ts.tv_sec * 1000 + (intnat)(ts.tv_nsec / 1000000));
}
