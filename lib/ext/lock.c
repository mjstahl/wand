/* An advisory lock on an open file, which OCaml's Unix does not expose: it
   gives `lockf`, the POSIX one, and that carries a footgun this cannot
   live with. A POSIX lock belongs to the process and is dropped when *any*
   descriptor to the file is closed -- so an unrelated read of the lock file
   somewhere else in the program releases a lock that still looks held.

   `flock` belongs to the open file description instead. The lock lives with
   the descriptor the bracket holds and nothing else in the process can drop
   it, which is the property a guard is worth having for.

   A lock is never waited for here. LOCK_NB means the call answers now, and
   "someone else has it" is an answer rather than a delay.

   Releasing is `close`, which the caller does: the kernel drops an flock
   when the last descriptor for that open file description goes, and that
   also covers the process dying, which is the whole reason this is a kernel
   lock rather than a file holding a pid. */

#include <caml/alloc.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>
#include <errno.h>
#include <string.h>
#include <sys/file.h>

/* `Unix.file_descr` is an immediate int on every platform wand builds for,
   which is what lets it arrive here without a conversion. */
CAMLprim value wand_flock_try(value fd)
{
  CAMLparam1(fd);
  CAMLlocal2(result, message);
  int status;
  const char *text = "";
  int rc = flock(Int_val(fd), LOCK_EX | LOCK_NB);
  if (rc == 0) {
    status = 0; /* taken */
  } else if (errno == EWOULDBLOCK || errno == EAGAIN) {
    status = 1; /* someone else holds it */
  } else {
    status = 2; /* the lock could not be asked for at all */
    text = strerror(errno);
  }
  message = caml_copy_string(text);
  result = caml_alloc_tuple(2);
  Store_field(result, 0, Val_int(status));
  Store_field(result, 1, message);
  CAMLreturn(result);
}
