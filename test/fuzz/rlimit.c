/* A hard ceiling on the address space of the process that calls this, which
   OCaml's Unix does not expose.

   The fuzzer runs a mutant in a child with two seconds of its own, and two
   seconds bounds the CPU it can spend. It does not bound the memory: a pure
   program that allocates as fast as it can will take the machine down inside
   its budget, and on a shared runner that is everyone else's build too.

   RLIMIT_AS rather than a GC alarm, because the kernel refuses the mapping
   and the allocation raises Out_of_memory, which the child already reports
   as "did not run". An alarm only fires between major collections, so a
   single large request slips past it.

   Soft and hard both, so nothing the child does can raise it again. A
   failure is ignored: this is a test tool making itself safer, and a
   platform that refuses the call is not a reason to stop fuzzing. Darwin is
   such a platform -- it answers EINVAL for RLIMIT_AS at any value, and for
   RLIMIT_DATA too (measured, macOS 25.6) -- so on a Mac this does nothing
   and the GC alarm beside it is the whole bound. Linux honours it, and the
   daily job runs on Linux. */

#include <caml/memory.h>
#include <caml/mlvalues.h>
#include <sys/resource.h>
#include <sys/time.h>

CAMLprim value wand_limit_address_space(value bytes)
{
  CAMLparam1(bytes);
  struct rlimit rl;
  rl.rlim_cur = (rlim_t)Long_val(bytes);
  rl.rlim_max = (rlim_t)Long_val(bytes);
  (void)setrlimit(RLIMIT_AS, &rl);
  CAMLreturn(Val_unit);
}
