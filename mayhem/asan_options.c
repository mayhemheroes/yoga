/* Strong (non-weak) __asan_default_options baked into every fuzz binary: a weak definition
 * loses to the ASan runtime's own weak default, so detect_leaks=0 would never take effect and
 * LSan aborts under Mayhem's ptrace-based coverage tracer (0 edges on every input). */
const char *__asan_default_options(void) { return "detect_leaks=0"; }
