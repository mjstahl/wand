/* Walking a directory tree by descriptor rather than by path.

   `rm -rf` does this. On this platform rm(1) is built on fts(3), and fts
   changes directory as it walks -- so each step names an entry relative to a
   directory it is holding, not by a path it looks up again. That is the
   difference that matters when something else can write in the tree: a path
   is a question asked fresh every time, and a descriptor is an answer
   already held. Replace a directory with a symlink after wand has decided it
   is a directory, and a path-based walk deletes wherever the link now
   points; a descriptor keeps pointing at what was opened.

   fts does it with `chdir`, which wand cannot: the current directory belongs
   to the process, `Par` runs work on other domains, and moving the cwd
   around mid-walk would break every relative path a worker was using.
   `openat` and `unlinkat` are the same idea without moving anything.

   Three calls, and the traversal itself stays in OCaml where it can be read.
   OCaml's Unix has none of the three, and `Unix.file_descr` is an immediate
   int on every platform wand builds for, which is what lets one arrive here
   and go back without a conversion -- the same assumption lock.c makes. */

#include <caml/alloc.h>
#include <caml/fail.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <string.h>
#include <unistd.h>

/* A name with a NUL in it is not the name the kernel would be given: the
   call would stop at the NUL and act on a shorter name. wand strings are
   bytes, so this is asked rather than assumed. */
static void check_name(value name)
{
  if (strlen(String_val(name)) != caml_string_length(name)) {
    caml_failwith("a file name here holds a NUL byte");
  }
}

/* The subdirectory `name` of the open directory `dirfd`, or None when there
   is nothing there to descend into: `name` is a file (ENOTDIR), a symlink
   (ELOOP, because O_NOFOLLOW refuses to follow it), or gone (ENOENT). The
   caller unlinks it in all three cases.

   Anything else -- no permission, no descriptors left -- is a failure with
   the reason, not a None: read as "not a directory" it would become an
   attempt to unlink a directory, and the reader would get EISDIR instead of
   what actually went wrong. */
CAMLprim value wand_openat_dir(value dirfd, value name)
{
  CAMLparam2(dirfd, name);
  CAMLlocal1(some);
  int fd;
  check_name(name);
  fd = openat(Int_val(dirfd), String_val(name),
              O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
  if (fd < 0) {
    if (errno == ENOTDIR || errno == ELOOP || errno == ENOENT) {
      CAMLreturn(Val_int(0)); /* None */
    }
    caml_failwith(strerror(errno));
  }
  some = caml_alloc(1, 0);
  Store_field(some, 0, Val_int(fd));
  CAMLreturn(some);
}

/* Every name in the open directory except `.` and `..`.

   `fdopendir` takes ownership of the descriptor it is given, and the caller
   still needs theirs to unlink through, so it is handed a duplicate. */
CAMLprim value wand_readdir_fd(value dirfd)
{
  CAMLparam1(dirfd);
  CAMLlocal3(head, cons, name);
  DIR *dir;
  struct dirent *entry;
  int saved;
  int copy = dup(Int_val(dirfd));
  if (copy < 0) {
    caml_failwith(strerror(errno));
  }
  dir = fdopendir(copy);
  if (dir == NULL) {
    saved = errno;
    close(copy);
    caml_failwith(strerror(saved));
  }
  rewinddir(dir);
  head = Val_int(0); /* [] */
  errno = 0;
  while ((entry = readdir(dir)) != NULL) {
    if (strcmp(entry->d_name, ".") != 0 && strcmp(entry->d_name, "..") != 0) {
      name = caml_copy_string(entry->d_name);
      cons = caml_alloc(2, 0);
      Store_field(cons, 0, name);
      Store_field(cons, 1, head);
      head = cons;
    }
    errno = 0;
  }
  /* `readdir` answers NULL for the end of the directory and for an error,
     and the two are told apart by errno, which is why it is cleared above
     before each call. */
  saved = errno;
  closedir(dir);
  if (saved != 0) {
    caml_failwith(strerror(saved));
  }
  CAMLreturn(head);
}

/* Remove `name` from the open directory `dirfd` -- the directory itself when
   `is_dir`, which is `rmdir`, and otherwise the name, which is `unlink`.

   Already gone is not a failure: something else removing an entry while this
   walk is taking the tree apart has done the walk's work for it. */
CAMLprim value wand_unlinkat(value dirfd, value name, value is_dir)
{
  CAMLparam3(dirfd, name, is_dir);
  check_name(name);
  if (unlinkat(Int_val(dirfd), String_val(name),
               Bool_val(is_dir) ? AT_REMOVEDIR : 0) != 0
      && errno != ENOENT) {
    caml_failwith(strerror(errno));
  }
  CAMLreturn(Val_unit);
}
