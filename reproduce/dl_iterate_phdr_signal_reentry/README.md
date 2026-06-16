# `dl_iterate_phdr` signal reentry demo

Build:

```bash
bash reproduce/build.sh
```

Run:

```bash
reproduce/dl_iterate_phdr_signal_reentry
```

What it does:

1. `t1` calls outer `dl_iterate_phdr` and stays inside its callback.
2. `t2` waits for a realtime signal.
3. `main` sends that signal to `t2`.
4. The signal handler in `t2` calls nested `dl_iterate_phdr`.

Expected output:

```text
result: nested `dl_iterate_phdr` did not return; deadlock reproduced
```

```text
https://github.com/bminor/glibc/blob/master/elf/dl-iteratephdr.c
```

The important part is that `__dl_iterate_phdr` takes
`GL(dl_load_write_lock)` before the callback loop. The callback runs while that
lock is still held.

```c
  /* Make sure nobody modifies the list of loaded objects.  */
  __rtld_lock_lock_recursive (GL(dl_load_write_lock));
  __libc_cleanup_push (cancel_handler, NULL);

  /* We have to determine the namespace of the caller since this determines
     which namespace is reported.  */
  size_t nloaded = GL(dl_ns)[0]._ns_nloaded;
  Lmid_t ns = 0;
  ...

  for (l = GL(dl_ns)[ns]._ns_loaded; l != NULL; l = l->l_next)
    {
      info.dlpi_addr = l->l_real->l_addr;
      info.dlpi_name = l->l_real->l_name;
      info.dlpi_phdr = l->l_real->l_phdr;
      info.dlpi_phnum = l->l_real->l_phnum;
      info.dlpi_adds = GL(dl_load_adds);
      info.dlpi_subs = GL(dl_load_adds) - nloaded;
      info.dlpi_tls_data = NULL;
      info.dlpi_tls_modid = l->l_real->l_tls_modid;
      if (info.dlpi_tls_modid != 0)
        info.dlpi_tls_data = GLRO(dl_tls_get_addr_soft) (l->l_real);
      ret = callback (&info, sizeof (struct dl_phdr_info), data);
      if (ret)
        break;
    }

  /* Release the lock.  */
  __libc_cleanup_pop (0);
  __rtld_lock_unlock_recursive (GL(dl_load_write_lock));
```

This program holds the outer callback in `t1`. Then it signals `t2`. The `t2`
handler calls `dl_iterate_phdr` again and blocks on the same loader lock.
