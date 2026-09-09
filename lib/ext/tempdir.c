/* Making a private directory with a name nobody else can hold first, which
   OCaml's Unix does not expose.

   The way to do it without `mkdtemp` is to take a unique *file* name, remove
   the file and make a directory of the same name -- which is what this used
   to do. Between the remove and the mkdir the name belongs to nobody, and in
   a shared /tmp another process can take it. wand then fails, rather than
   handing back a directory somebody else made, so nothing was ever
   redirected; but a script that cannot get a temp directory is a script that
   does not run, and the window was there on every call.

   `mkdtemp` has no window: the kernel creates the directory 0700 with a name
   that did not exist a moment before, in one step, and answers with the name
   it chose. */

#include <caml/alloc.h>
#include <caml/fail.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>
/* mkdtemp is in <unistd.h> on POSIX, and <stdlib.h> alone does not declare
   it. */
#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

/* The template is copied because `mkdtemp` writes the chosen name into it,
   and an OCaml string is not ours to write to. */
CAMLprim value wand_mkdtemp(value template)
{
  CAMLparam1(template);
  CAMLlocal1(chosen);
  char buf[4096];
  size_t n = caml_string_length(template);
  if (n + 1 > sizeof buf) {
    caml_failwith("temp_dir: the template is too long");
  }
  memcpy(buf, String_val(template), n);
  buf[n] = '\0';
  if (mkdtemp(buf) == NULL) {
    caml_failwith(strerror(errno));
  }
  chosen = caml_copy_string(buf);
  CAMLreturn(chosen);
}
