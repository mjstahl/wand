/* Removing a variable from the environment, which OCaml's Unix does not
   expose: it gives `putenv` and nothing that takes a name back out.

   `Env.clear` used to be `putenv name ""`, which is not the same thing. A
   variable set to the empty string is still in the environment: the shell
   `sh -c 'echo ${FOO-unset}'` sees the empty string rather than `unset`,
   `test -z "$FOO"` and `test -v FOO` disagree about it, and a child that
   distinguishes "not configured" from "configured as nothing" reads the
   wrong one. What `clear` is asked for is the variable's absence.

   `unsetenv` answers -1 with EINVAL for a name that is empty or holds `=`,
   which is a name no `putenv` could have set either. Nothing is raised for
   it: `clear` on a name that was never there is not a failure, and neither
   is `clear` on a name that could never be there. */

#include <caml/memory.h>
#include <caml/mlvalues.h>
#include <stdlib.h>

CAMLprim value wand_unsetenv(value name)
{
  CAMLparam1(name);
  (void)unsetenv(String_val(name));
  CAMLreturn(Val_unit);
}
